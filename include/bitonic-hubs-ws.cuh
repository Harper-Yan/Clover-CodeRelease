#pragma once

#include <cassert>
#include <cmath>   // for INFINITY; numeric limits doesn't work
#include <curand_kernel.h> 
#include <cfloat>

#include "cuda_util.cuh"
#include "spatial.cuh"
#include "bitonic-shared.cuh"

#include <faiss/gpu/utils/Select.cuh>

namespace { // anonymous

//idx_t constexpr H = 1024;
//idx_t constexpr warp_size = 32;

} // namespace anonymous

namespace bitonic_hubs_ws {

void logWorkScanned(const int* hubsScanned, const int* pointsScanned, int numQueries, std::string const & filename) {
    std::string logfile_name = "Work_" + filename + "_" + std::to_string(H); 
    std::ofstream logfile(logfile_name);

    if (logfile.is_open()) {
        for (int i = 0; i < numQueries; ++i) {
            logfile << i << " " << hubsScanned[i] << " " << pointsScanned[i]<< std::endl;
        }
        logfile.close(); // Close the log file
    } else {
        std::cerr << "Unable to open log file for writing" << std::endl;
    }
}

__global__ void Randomly_Select_Hubs(idx_t n, idx_t * dH){
    idx_t const idx = blockIdx.x * blockDim.x + threadIdx.x;

    unsigned int seed = 1234 + idx;

    if( idx < H){
        unsigned int rand_num = (seed * 1103515245 + 12345) % 2147483648;
        dH[idx] = rand_num % n;
    }
}

/**
 * Produces column-major distance matrix for each point to each hub
 */
template <class R>
__global__ void Calculate_Distances(idx_t b_id, idx_t b_size, idx_t n, idx_t const* dH, R *distances, R const* points, idx_t *hub_counts, idx_t *dH_assignments)
{
    assert( "Must have at least one hub" && H > 0 );

    // TODO: Check if we can launch more threads for this kernel.
    // I don't think we need the for loop if we launch H-fold more threads

    idx_t idx = blockIdx.x * blockDim.x + threadIdx.x + b_id * b_size;
    idx_t idx_within_b = blockIdx.x * blockDim.x + threadIdx.x;

    if( idx < n && idx_within_b < b_size)
    {
        float q_x = points[ idx * dim ];
        float q_y = points[ idx * dim + 1];
        float q_z = points[ idx * dim + 2];

        float minimal_dist = FLT_MAX;
        idx_t assigned_H   = H + 1;       // should be impossible

        for(idx_t h = 0; h < H; h++)
        {
            // Steps column-major, i.e., increment by num points
            float next_hub_distance = sqrt( spatial::l2dist( q_x, q_y, q_z, &points[ dim * dH[h] ]) );
            distances[ h * b_size + idx_within_b ] = next_hub_distance;
            if( next_hub_distance < minimal_dist )
            {
                assigned_H = h;
                minimal_dist = next_hub_distance;
            }
        }

        dH_assignments[idx] = assigned_H;
        atomicAdd( &hub_counts[assigned_H], 1 );
    }
}
/**
 * Deletes all hubs with less than k points and moves their points to new hubs
 */
template <class R>
__global__
void reassignPoints( idx_t n, idx_t k, R const * distances, idx_t *hub_counts, idx_t *dH_assignments )
{
    int constexpr shared_memory_size = 1024;

    assert( "Cannot find more neighbours than there are points" && k < n );
    assert( "Need one __shared__ lane per hub" && H < shared_memory_size );

    idx_t const idx = blockIdx.x * blockDim.x + threadIdx.x;

    __shared__ idx_t initial_counts[shared_memory_size];
    if( idx < H )
    {
        initial_counts[ idx ] = hub_counts[ idx ];
    }
    __syncwarp(); __syncthreads();

    if( idx < n )
    {
        idx_t const current_hub = dH_assignments[ idx ];
        if( initial_counts[ current_hub ] < k )
        {
            R minimal_dist = FLT_MAX;
            idx_t new_hub  = H;

            for( idx_t h = 0; h < H; ++h )
            {
                R const next_distance = distances[ h*n + idx ];
                assert( "next distance is reasonable?" && next_distance < FLT_MAX );
                if( initial_counts[h] >= k && next_distance < minimal_dist )
                {
                    new_hub = h;
                    minimal_dist = next_distance;
                }
            }

            assert( "Hub must have changed in loop because k < n" && new_hub != dH_assignments[ idx ] );
            assert( "Hub must have changed in loop because k < n" && new_hub < H );
            assert( "Hub must have changed in loop because k < n" && minimal_dist < FLT_MAX );
            assert( "New hub is valid"                            && initial_counts[ new_hub ] >= k );
            assert( "New hub should not be better than old hub"   && distances[new_hub*n + idx] >= distances[current_hub*n + idx]);

            dH_assignments[idx] = new_hub;
            atomicAdd( &hub_counts[new_hub], 1 );
        }
    }

    // Reset unused hubs to zero for prefix sum, etc. later.
    if( idx < H && initial_counts[ idx ] < k )
    {
        hub_counts[ idx ] = 0;
    }
}

template < typename T >
__device__ __forceinline__
void prefix_sum_warp( T & my_val )
{
    int constexpr FULL_MASK = 0xFFFFFFFF;
    int constexpr warp_size = 32;

    for( int stride = 1; stride < warp_size; stride = stride << 1 )
    {
        __syncwarp();
        T const paired_val = __shfl_up_sync( FULL_MASK, my_val, stride );
        if( threadIdx.x >= stride )
        {
            my_val += paired_val;
        }
    }
}

/**
 * Calculates a prefix sum of an input/output array, arr, of size H
 * in-place and also populates a second copy of the output array.
 */
template < typename T >
__global__
void fused_prefix_sum_copy( T *arr, T * copy )
{
    // Expected grid size: 1 x  1 x 1
    // Expected CTA size: 32 x 32 x 1

    // lazy implementation for now. Not even close to a hot spot.
    // just iterate H with one thread block and revisit if we start
    // using *very* large H, e.g., H > 8096, or it shows up in profile.

    assert( "H is a power of 2."  && __popc( H ) == 1 );
    assert( "H uses a full warp." && H >= 32 );

    int const lane_id = threadIdx.x;
    int const warp_id = threadIdx.y;
    int const th_id   = warp_id * blockDim.x + lane_id;

    if( th_id >= H ) { return; } // guard clause for syncthreads later

    // the first location of smem will contain the sum of all the
    // size-1024 chunks so far. The remaining 32 are a staging site
    // to propagate warp-level results across warps.
    int const shared_memory_size = 32 + 1;
    __shared__ T smem[ shared_memory_size ];
    if( th_id == 0 ) { smem[ 0 ] = 0; }

    // iterate in chunks of 1024 at a time
    for( int i = th_id; i < H ; i = i + blockDim.x * blockDim.y )
    {

        T my_val = arr[ i ];

        prefix_sum_warp( my_val );

        // compute partial sums over warp-level results
        // first, last lane in each warp copies result to smem for sharing
        if( lane_id == ( blockDim.x - 1) )
        {
            smem[ warp_id + 1 ] = my_val;
        }
        __syncthreads(); // safe because H is a power of 2 & guard clause earlier

        T sum_of_chunk_sofar = 0;

        // first warp computes prefix scan over 32 warp-level sums
        if( warp_id == 0 )
        {
            // fetch other warps' data from smem
            T warp_level_sum = smem[ lane_id + 1 ]
				            + smem[ 0 ] * ( lane_id == 0 );
            prefix_sum_warp( warp_level_sum );

            // write results back out to smem to broadcast to other warps
            // also update smem[ 0 ] to be first sum for next chunk
            smem[ lane_id + 1 ] = warp_level_sum;
            if( lane_id == ( blockDim.x - 1 ) )
            {
                sum_of_chunk_sofar = warp_level_sum;
            }
        }

        // propagate partial results across all threads
        // each thread only needs the partial sum for its warp
        __syncthreads(); // safe for same reasons as previous sync

        my_val += smem[ warp_id ];

        arr [ i ] = my_val;
        copy[ i ] = my_val;

        if(warp_id == 0 && lane_id == ( blockDim.x - 1 )) { smem[0] = sum_of_chunk_sofar; }
    }
}

/**
 * Physically resorts an array with a small domain of V unique values using O(nV) work using an out-of-place
 * struct-of-arrays decomposition.
 */
template <class R>
__global__
void BucketSort( idx_t n, R * arr_x, R *arr_y, R *arr_z, idx_t * arr_idx, R const* points, idx_t const* dH_assignments, idx_t * dH_psum )
{
    idx_t const idx = blockIdx.x * blockDim.x + threadIdx.x;

    if( idx < n )
    {
        idx_t const hub_idx = dH_assignments[idx];
        idx_t const loc = atomicAdd(&dH_psum[hub_idx], 1);

        arr_x[loc] = points[idx*dim+0];
        arr_y[loc] = points[idx*dim+1];
        arr_z[loc] = points[idx*dim+2];
        arr_idx[loc] = idx;
    }
}
__global__ void set_max_float(float *D, int size) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < size) {
        D[idx] = __FLT_MAX__;
    }
}

/**
 * Builds the HxH distance matrix, D, in which the asymmetric distance from hub H_i to hub H_j
 * is the distance from H_i to the closest point in H_j.
 */
 
__global__
void Construct_D( float const * distances, idx_t const * assignments, idx_t b_id, idx_t b_size, idx_t n, float * D )
{
    
    int constexpr shared_memory_size = 2048;

    assert( "Array fits in shared memory" && H <= shared_memory_size );

    // Each thread block will work on one row of the HxH matrix
    // unless the hub is empty in which case this thread block will just return.
    int const hub_id = blockIdx.x;

    float const * this_hubs_distances = &distances[ hub_id * b_size ];

    int const block_level_lane_id = threadIdx.x;
    assert( "Expect to have one __shared__ lane per thread" && block_level_lane_id < shared_memory_size );

    // Initialise row to a sequence of really large values in shared memory
    __shared__ int s_dists[shared_memory_size];

    int R = int (( H + blockDim.x  -1 ) / blockDim.x );

    for ( int r = 0; r < R; r ++)
    {
        if( r * blockDim.x + block_level_lane_id < H )
        {
            // IEEE-754 max exponent, no mantissa, no sign bit
            // This value sorts to back as both int and as float
            // compared to our domain
            s_dists[ r * blockDim.x + block_level_lane_id ] = 0x7f000000;
        }
    }

    __syncwarp(); __syncthreads();

    for( idx_t p = block_level_lane_id; p < b_size; p += blockDim.x )
    {
        idx_t idx = b_id * b_size + p;
        if( idx < n)
        {
            idx_t const this_H = assignments[ idx ];
            assert( "Retrieved a valid hub id" && this_H < H );
            atomicMin( &s_dists[this_H], __float_as_int( this_hubs_distances[ p ] ) );
            // Note: the reinterpret cast is necessary because there is no atomic min
            // defined for floats. Still, it would be nice to find a better solution
            // than this. Per nvidia forums, it seems that CUDA might not follow the IEEE
            // standard exactly? If this works, it should be a more mainstream hack?
        }
    }

    __syncwarp(); __syncthreads();

    for ( int r = 0; r < R; r ++)
    {
        if( r * blockDim.x + block_level_lane_id < H )
        {
            atomicMin(&s_dists[ r * blockDim.x + block_level_lane_id ],  __float_as_int( D[ H * hub_id + r * blockDim.x + block_level_lane_id ] ));
            D[ H * hub_id + r * blockDim.x + block_level_lane_id ] = __int_as_float( s_dists[ r * blockDim.x + block_level_lane_id ] );
        } 
    }

}

//data, dH, dH_assignments, dH_psum, arr_idx, n, D
/*
template < typename R >
__global__
void Construct_D( R * points
                , idx_t * dH
                , idx_t const * assignments
                , idx_t const * hub_start_pos
                , idx_t const * arr_idx
                , std::size_t   n
                , R           * D
                )
{
    std::size_t constexpr shared_memory_size = 32;
    __shared__ R s_dists[ shared_memory_size ];

    // Expecting a grid of size:          H x  H x 1
    // and a CTA / thread block of size: 32 x 32 x 1

    // Each thread block will work collaboratively on one cell of the HxH matrix
    // They will use (hub_start_pos, arr_idx) to find the relevant distances and
    // then perform a block-level reduction. The reads all involve a level of indirection
    // from global memory and are expected to be non-coalesced.

    int const lane_id     = threadIdx.x;
    int const warp_id     = threadIdx.y;
    int const th_id       = warp_id * blockDim.x + lane_id;
    int const num_threads = blockDim.x * blockDim.y;

    int const from_hub_id = blockIdx.x;
    int const to_hub_id = blockIdx.y;

    idx_t const start = hub_start_pos[ from_hub_id ];
    idx_t const end   = hub_start_pos[ from_hub_id + 1 ];

    // perform reduction over values in arr_idx[start] ... arr_idx[end]
    R my_min = FLT_MAX;

    R const * hp = &points[ dH[to_hub_id] * 3 ];
    
    // walk the entire hub with each thread locally determining
    // the smallest value that it has seen
    for( int i = start + th_id; i < end; i += num_threads )
    {   
        R * this_p = &points[ arr_idx[i] * 3];

        R const new_dist = spatial::l2dist(hp, this_p);
        if( new_dist < my_min )
        {
            my_min = new_dist;
        }
    }

    // reduce each warp
    
    for( int stride = 1; stride < 32; stride = stride << 1 )
    {
        //sync_warp here and below. call before shfls/communications
        R const paired_dist = __shfl_xor_sync( 0xFFFFFFFF, my_min, stride );
        if( paired_dist < my_min )
        {
            my_min = paired_dist;
        }
    }

    // sync warps and reduce blockwise
    if( lane_id == 0 )
    {
        s_dists[ warp_id ] = my_min;
    }

    __syncthreads();

    if( warp_id > 0 ) { return; }
    
    my_min = s_dists[ lane_id ];
    
    for( int stride = 1; stride < 32; stride = stride << 1 )
    {
        R const paired_dist = __shfl_xor_sync( 0xFFFFFFFF, my_min, stride );
        if( paired_dist < my_min )
        {
            my_min = paired_dist;
        }
    }

    if( lane_id > 0 ) { return; }

    D[ from_hub_id * H + to_hub_id ] = my_min;
}
*/
template < typename R, int ROUNDS >
__global__
void fused_transform_sort_D( R     const * D // square matrix with lower dist bound from hub i to j
                           , idx_t       * sorted_hub_ids  // square matrix where (i,j) is id of j'th closest hub to i
                           , R           * sorted_hub_dist // square matrix where (i,j) is dist of j'th closest hub to i
                           )
{
    // NOTE: this currently uses a lot of smem, reducing warp occupancy by 2x at H=1024.
    __shared__ R smem[ 2 * H ];

    // each block will sort one row of size H.
    // each thread is responsible for determining the final contents of one cell
    auto  const     warp_size = 32u;
    auto  const     block_size = 1024u;
    idx_t const     lane_id   = threadIdx.x;
    idx_t const     warp_id   = threadIdx.y;
    idx_t const     sort_id   = warp_id * warp_size + lane_id;
    idx_t const     hub_id    = blockIdx.x;

    if(sort_id >= H || hub_id >=H) {return;}

    // each thread grabs the contents of its cell in the input distance matrix
    R     dist[ROUNDS] ;
    idx_t hub[ROUNDS] ;

    for (int r=0; r< ROUNDS; r++)
    {
        dist[r] = D[ H * hub_id + sort_id + block_size * r ];
        hub[r]   = sort_id + block_size * r;
    }

    // create num_hubs >> 5 sorted runs in registers
    //bitonic::sort<warp_id % 2, 1>( &hub, &dist );
    //branch divergence here

    for ( int r = 0; r < ROUNDS; r ++)
    {
        if ( warp_id % 2 == 0  ) {
            bitonic::sort<true, 1>( &hub[r], &dist[r] );  
        } else {
            bitonic::sort<false, 1>( &hub[r], &dist[r] ); 
        }
    }

    // perform repeated merges with a given number of cooperating threads
    for( idx_t coop = warp_size << 1; coop <= H; coop = coop << 1 )
    {
        // do first steps of merge in shared memory 
        for( idx_t stride = coop >> 1; stride >= warp_size; stride = stride >> 1 )
        {
            for ( int r = 0; r < ROUNDS; r ++)
            {
                int const global_lane_id = r * block_size + sort_id;
                smem[ global_lane_id ] = dist[r];
                smem[ global_lane_id + H ] = float(hub[r]);
            }

            __syncthreads();

            for ( int r = 0; r < ROUNDS; r ++)
            {
                int const global_lane_id = r * block_size + sort_id;
                // TODO: optimise this part to reduce trips to smem somehow
                // something more tiled? each thread only reads two vals per sync
                // TODO: this is a guaranteed bank conflict (BC) followed immediately
                // by a sync to force *all* threads to wait for the BC

                // TODO: this is a guaranteed bank conflict, too.
                // but maybe these are inevitable anyway due
                // to pigeon hole principle?
                idx_t paired_thread = (global_lane_id)  ^ stride;
                R     const paired_dist = smem[ paired_thread ];
                idx_t const paired_hub  = int(smem[ paired_thread + H ]);
        
                if( ( paired_thread > global_lane_id && ( global_lane_id & coop ) == 0 && ( paired_dist < dist[r] ) )
                || ( paired_thread < global_lane_id && ( global_lane_id & coop ) != 0 && ( paired_dist < dist[r] ) )
                || ( paired_thread > global_lane_id && ( global_lane_id & coop ) != 0 && ( paired_dist > dist[r] ) )
                || ( paired_thread < global_lane_id && ( global_lane_id & coop ) == 0 && ( paired_dist > dist[r] ) ) )
                {
                    dist[r] = paired_dist;
                    hub[r]  = paired_hub;
                }
                __syncthreads();

            }
        }

        for ( int r = 0; r < ROUNDS; r ++)
        {
            int const global_lane_id = r * block_size + sort_id;
            if ( ( global_lane_id & coop ) == 0 ){
                bitonic::sort<true, 1>( &hub[r], &dist[r] );  
            } else {
                bitonic::sort<false, 1>( &hub[r], &dist[r] ); 
            }
        }

    }

    __syncthreads();

    for (int r = 0 ; r < ROUNDS ; r ++)
    {
        sorted_hub_ids [ hub_id * H + sort_id + r * block_size ] = hub[r];
        sorted_hub_dist[ hub_id * H + sort_id + r * block_size ] = dist[r];
    }

}

template < std::size_t WarpQ, std::size_t ThreadQ, std::size_t ThreadsPerBlock >
__global__
__launch_bounds__(128, 16)
void Query( idx_t const * Qps, idx_t * solutions_knn, float *solutions_distances, int K, int Points_num, float const * points, idx_t * dH, idx_t const * arr_idx, float const * arr_x, float const * arr_y, float const * arr_z, idx_t const * iD, float const * dD, idx_t const * dH_psum, idx_t const * assignments
            , int * hubs_scanned, int *pointsScanned)
{
    int const lane_id           = threadIdx.x;
    int const query_id_in_block = threadIdx.y;
    int const queries_per_block = blockDim.y;
    int const query_sequence_id = blockIdx.x * queries_per_block + query_id_in_block;
    
    if( query_sequence_id >= Points_num ) { return; }

    int const qp = arr_idx[ query_sequence_id ];

    // Set up iteration counters
    int const hub_containing_qp = assignments[qp];
    int current_H = hub_containing_qp;
    int hubs_processed = 0;
    int poitns_scanned = 0;

    int scan_hub_from = dH_psum[ hub_containing_qp + hubs_processed ];
    int scan_hub_to   = dH_psum[ current_H + 1 ];

    // Initialize WarpSelect
    faiss::gpu::WarpSelect<
            float,
            idx_t,
            false,
            faiss::gpu::Comparator<float>,
            WarpQ /* NumWarpQ */,
            ThreadQ /* NumThreadQ */,
            ThreadsPerBlock /* TODO: active? ThreadsPerBlock */
	>
        heap(FLT_MAX /*initK*/, -1 /* initV */, K);

    // Move query point to registers
    float const q_x = points[ qp * dim ];
    float const q_y = points[ qp * dim + 1 ];
    float const q_z = points[ qp * dim + 2 ];
    
    float h_x = points[ dH[hub_containing_qp] * dim ];
    float h_y = points[ dH[hub_containing_qp] * dim + 1 ];
    float h_z = points[ dH[hub_containing_qp] * dim + 2 ];

    // Set up triangle inequality parameters for early termination
    float const dist_to_my_hub   = sqrt(spatial::l2dist( q_x, q_y, q_z, h_x, h_y, h_z ));
    float       dist_to_this_hub = dD[ hub_containing_qp * H + hubs_processed ];

    poitns_scanned += (warp_size > (scan_hub_to - scan_hub_from))?(scan_hub_to - scan_hub_from) : warp_size;

    while( hubs_processed < H && sqrt( heap.warpKTop ) > dist_to_this_hub - dist_to_my_hub)
    {
        // Get next 32 values and batch insert them into the top-k
        // Note that we need all threads to sort.
        // If there are fewer than 32 points left in the hub,
        // they will get sentinel values that sort to the back.

        idx_t next_point_id = Points_num;
        float next_distance = FLT_MAX;

        if( scan_hub_from + lane_id < scan_hub_to )
        {
            next_point_id      = arr_idx[ scan_hub_from + lane_id ];
            float const next_x =   arr_x[ scan_hub_from + lane_id ];
            float const next_y =   arr_y[ scan_hub_from + lane_id ];
            float const next_z =   arr_z[ scan_hub_from + lane_id ];

            next_distance = spatial::l2dist( q_x, q_y, q_z, next_x, next_y, next_z );
        }
        
	    heap.add(next_distance, next_point_id);

        poitns_scanned += (warp_size > (scan_hub_to - scan_hub_from))?(scan_hub_to - scan_hub_from) : warp_size;

        // Advance iterators
        scan_hub_from += warp_size;
        if( scan_hub_from >= scan_hub_to )
        {
            if( ++hubs_processed < H )
            {
                current_H        = iD[ hub_containing_qp * H + hubs_processed ];
                dist_to_this_hub = dD[ hub_containing_qp * H + hubs_processed ];
                scan_hub_from    = dH_psum[ current_H ];
                scan_hub_to      = dH_psum[ current_H + 1 ];
            }
        }
    }

    //hubs_scanned[qp] = hubs_processed;
    //pointsScanned[qp] = poitns_scanned;

    heap.reduce();

    heap.writeOut(
            solutions_distances + (K * qp),
            solutions_knn + (K * qp),
	    K
	);
}

template<typename R>
__global__ void check(idx_t * iD, float * dD, idx_t *results_knn, R * results_distances){
    int const hid = blockIdx.x;
    int const tid = threadIdx.x;
    if(hid < H && tid < H){
        results_knn[tid + hid*H] = iD[tid + hid*H];
        //results_distances[tid + hid*H] = dD[tid + hid*H];
    }
}

template<typename R>
__global__ void check_D(unsigned long long int * D, idx_t *results_knn, R * results_distances){
    int const hid = blockIdx.x;
    int const tid = threadIdx.x;

    idx_t iD;
    float dD;

    iD= (idx_t)(D[tid + hid*H] & 0xFFFFFFFF);
    uint32_t packed1 = D[tid + hid*H] >> 32;
    float unpacked1;
    memcpy(&unpacked1, &packed1, sizeof(float));
    dD = unpacked1;

    results_knn[tid + hid*H] = iD;
    results_distances[tid + hid*H] = dD;
}


template <class R>
void C_and_Q(std::size_t n, R *data, std::size_t q, idx_t *queries, std::size_t k, idx_t *results_knn, R *results_distances)
{
    idx_t constexpr block_size = 1024;
    
    idx_t * dH;
    CUDA_CALL(cudaMalloc((void **) &dH, sizeof(idx_t) * H));

    idx_t * dH_psum, * dH_psum_copy, * dH_assignments, * d_psum_placeholder;
    CUDA_CALL(cudaMalloc((void **) &dH_psum,        sizeof(idx_t) * ( H + 1 )));
    CUDA_CALL(cudaMalloc((void **) &dH_psum_copy,   sizeof(idx_t) * ( H + 1 )));
    CUDA_CALL(cudaMalloc((void **) &d_psum_placeholder,   sizeof(idx_t) * ( H + 1)));
    CUDA_CALL(cudaMalloc((void **) &dH_assignments, sizeof(idx_t) * n));
    cudaMemset(dH_psum, 0, sizeof(idx_t) * (1+H));
    cudaMemset(dH_psum_copy, 0, sizeof(idx_t) * (1+H));
    cudaMemset(d_psum_placeholder, 0, sizeof(idx_t) * (1+H));
    cudaMemset(dH_assignments, 0, sizeof(idx_t) * n);

    float * distances;
    idx_t constexpr batch_size = 100000;
    idx_t batch_number = (n + batch_size -1) / batch_size;
    CUDA_CALL(cudaMalloc((void **) &distances, sizeof(R) * H * batch_size));

    float * arr_x, *arr_y, *arr_z;
    idx_t * arr_idx;
    CUDA_CALL(cudaMalloc((void **) &arr_x, sizeof(float) * n));
    CUDA_CALL(cudaMalloc((void **) &arr_y, sizeof(float) * n));
    CUDA_CALL(cudaMalloc((void **) &arr_z, sizeof(float) * n));
    CUDA_CALL(cudaMalloc((void **) &arr_idx, sizeof(idx_t) * n));

    float * D;
    CUDA_CALL(cudaMalloc((void **) &D, sizeof(float) * H * H));

    idx_t *iD;
    float * dD;
    CUDA_CALL(cudaMalloc((void **) &iD, sizeof(idx_t) * H * H));
    CUDA_CALL(cudaMalloc((void **) &dD, sizeof(float) * H * H));

    std::size_t num_blocks = (H + block_size - 1) / block_size;
    Randomly_Select_Hubs<<<num_blocks, block_size>>>(n, dH);
    CHECK_ERROR("Randomly_Select_Hubs.");

    num_blocks = (batch_size + block_size - 1) / block_size;

    idx_t batch_id;

    set_max_float<<<( H * H + block_size - 1 ) / block_size, block_size>>>(D, H * H);

    for (batch_id = 0; batch_id < batch_number; batch_id++)
    {
        Calculate_Distances<<<num_blocks, block_size>>>(batch_id, batch_size, n, dH, distances, data, dH_psum, dH_assignments);
        Construct_D<<<H, block_size>>>(distances, dH_assignments, batch_id, batch_size, n, D);
    }
    //check<<<H, H>>>(iD, D, results_knn, results_distances);
    cudaFree( distances );

    //reassignPoints<<<num_blocks, block_size>>>(n, k, distances, dH_psum, dH_assignments);
    //CHECK_ERROR("reassignPoints.");
    
    fused_prefix_sum_copy<<<1, dim3( warp_size,  warp_size, 1)  >>>(dH_psum, dH_psum_copy);
    cudaMemcpy(d_psum_placeholder, dH_psum_copy, (H + 1 )* sizeof(idx_t), cudaMemcpyDeviceToDevice);
    
    cudaMemcpy(dH_psum_copy + 1, d_psum_placeholder, H * sizeof(idx_t), cudaMemcpyDeviceToDevice);
    cudaMemcpy(dH_psum + 1, d_psum_placeholder, H * sizeof(idx_t), cudaMemcpyDeviceToDevice);
    cudaMemset(dH_psum, 0, sizeof(idx_t));
    cudaMemset(dH_psum_copy, 0, sizeof(idx_t));
    CHECK_ERROR("Fused_prefix_sum_copy.");
    cudaFree(d_psum_placeholder);

    num_blocks = (n + block_size - 1) / block_size;

    BucketSort<<<num_blocks,  block_size>>>(n, arr_x, arr_y, arr_z, arr_idx, data, dH_assignments, dH_psum_copy);
    CHECK_ERROR("BucketSort.");
    cudaFree(dH_psum_copy);

    //Construct_D<<<dim3( H, H, 1), dim3( warp_size,  warp_size, 1)>>>(data, dH, dH_assignments, dH_psum, arr_idx, n, D);

    fused_transform_sort_D<float, (H + block_size - 1) / block_size> <<<H, dim3 { warp_size, block_size/warp_size, 1 }>>> (D, iD, dD);
    CHECK_ERROR("Sort_D.");
    cudaFree(D); 

    int hubsScanned[n], pointsScanned[n];
    int * d_hubsScanned, * d_pointsScanned;
    CUDA_CALL(cudaMalloc((void **) &d_hubsScanned, sizeof(int)* 1));//change here if want to log
    CUDA_CALL(cudaMalloc((void **) &d_pointsScanned, sizeof(int)* 1));

    std::size_t constexpr queries_per_block = 128 / warp_size;
    num_blocks = util::CEIL_DIV(n, queries_per_block);

    switch (util::CEIL_DIV(k, warp_size))
    {
        
        case 1: { Query<32, 2, 128> <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 2: { Query<64, 3, 128> <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
               dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 3: { Query<128, 3, 128> <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 4: { Query<256, 4, 128> <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 5: { Query<512, 8, 128>	 <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        
        /*
	case 6: { Query<6, > <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 7: { Query<7, > <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        case 8: { Query<8, > <<<num_blocks, dim3 { warp_size, queries_per_block, 1 }>>>(queries, results_knn, results_distances, k, n, data, 
                dH, arr_idx, arr_x, arr_y, arr_z, iD, dD, dH_psum, dH_assignments, d_hubsScanned, d_pointsScanned); } break;
        */
	    default: assert(false && "Rounds required to fulfill k value will exceed thread register allotment.");
    }

    //cudaMemcpy(hubsScanned, d_hubsScanned, n * sizeof(int), cudaMemcpyDeviceToHost);
    //cudaMemcpy(pointsScanned, d_pointsScanned, n * sizeof(int), cudaMemcpyDeviceToHost);

    //logWorkScanned(hubsScanned, pointsScanned, n, filename);


    CHECK_ERROR("Running scan kernel.");
    
    cudaFree( iD );
    cudaFree( dD );
    cudaFree( dH_psum );
    cudaFree( dH_assignments );
    cudaFree( distances );
    cudaFree( arr_idx );
    cudaFree( arr_x );
    cudaFree( arr_y );
    cudaFree( arr_z );
}

} // namespace bitonic