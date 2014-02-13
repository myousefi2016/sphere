// navierstokes.cuh
// CUDA implementation of porous flow

#include <iostream>
#include <cuda.h>
//#include <cutil_math.h>
#include <helper_math.h>

#include "vector_arithmetic.h"	// for arbitrary prec. vectors
#include "sphere.h"
#include "datatypes.h"
#include "utility.h"
#include "constants.cuh"
#include "debug.h"

// Solver parameter, used in velocity prediction and pressure iteration
// 1.0: Use old pressures for fluid velocity prediction (see Langtangen et al.
// 2002)
// 0.0: Do not use old pressures for fluid velocity prediction (Chorin's
// original projection method, see Chorin (1968) and "Projection method (fluid
// dynamics)" page on Wikipedia.
// The best results precision and performance-wise are obtained by using BETA=0
// and a very low tolerance criteria value (e.g. 1.0e-9)
#define BETA 0.0

// Under-relaxation parameter, used in solution of Poisson equation. The value
// should be within the range ]0.0;1.0]. At a value of 1.0, the new estimate of
// epsilon values is used exclusively. At lower values, a linear interpolation
// between new and old values is used. The solution typically converges faster
// with a value of 1.0, but instabilities may be avoided with lower values.
#define THETA 1.0

// Arithmetic mean of two numbers
__inline__ __device__ Float amean(Float a, Float b) {
    return (a+b)*0.5;
}

// Harmonic mean of two numbers
__inline__ __device__ Float hmean(Float a, Float b) {
    return (2.0*a*b)/(a+b);
}

// Initialize memory
void DEM::initNSmemDev(void)
{
    // size of scalar field
    unsigned int memSizeF  = sizeof(Float)*NScells();

    // size of velocity arrays in staggered grid discretization
    unsigned int memSizeFvel = sizeof(Float)*NScellsVelocity();

    cudaMalloc((void**)&dev_ns_p, memSizeF);     // hydraulic pressure
    cudaMalloc((void**)&dev_ns_v, memSizeF*3);   // cell hydraulic velocity
    cudaMalloc((void**)&dev_ns_v_x, memSizeFvel);// velocity in stag. grid
    cudaMalloc((void**)&dev_ns_v_y, memSizeFvel);// velocity in stag. grid
    cudaMalloc((void**)&dev_ns_v_z, memSizeFvel);// velocity in stag. grid
    cudaMalloc((void**)&dev_ns_v_p, memSizeF*3); // predicted cell velocity
    cudaMalloc((void**)&dev_ns_v_p_x, memSizeFvel); // pred. vel. in stag. grid
    cudaMalloc((void**)&dev_ns_v_p_y, memSizeFvel); // pred. vel. in stag. grid
    cudaMalloc((void**)&dev_ns_v_p_z, memSizeFvel); // pred. vel. in stag. grid
    cudaMalloc((void**)&dev_ns_vp_avg, memSizeF*3); // avg. particle velocity
    cudaMalloc((void**)&dev_ns_d_avg, memSizeF); // avg. particle diameter
    cudaMalloc((void**)&dev_ns_fi, memSizeF*3);  // interaction force
    cudaMalloc((void**)&dev_ns_phi, memSizeF);   // cell porosity
    cudaMalloc((void**)&dev_ns_dphi, memSizeF);  // cell porosity change
    cudaMalloc((void**)&dev_ns_div_phi_v_v, memSizeF*3); // div(phi v v)
    cudaMalloc((void**)&dev_ns_epsilon, memSizeF); // pressure difference
    cudaMalloc((void**)&dev_ns_epsilon_new, memSizeF); // new pressure diff.
    cudaMalloc((void**)&dev_ns_norm, memSizeF);  // normalized residual
    cudaMalloc((void**)&dev_ns_f, memSizeF);     // forcing function value
    cudaMalloc((void**)&dev_ns_f1, memSizeF);    // constant addition in forcing
    cudaMalloc((void**)&dev_ns_f2, memSizeF*3);  // constant slope in forcing
    cudaMalloc((void**)&dev_ns_tau, memSizeF*6); // stress tensor (symmetrical)
    cudaMalloc((void**)&dev_ns_div_phi_vi_v, memSizeF*3); // div(phi*vi*v)
    cudaMalloc((void**)&dev_ns_div_phi_tau, memSizeF*3);  // div(phi*tau)

    checkForCudaErrors("End of initNSmemDev");
}

// Free memory
void DEM::freeNSmemDev()
{
    cudaFree(dev_ns_p);
    cudaFree(dev_ns_v);
    cudaFree(dev_ns_v_x);
    cudaFree(dev_ns_v_y);
    cudaFree(dev_ns_v_z);
    cudaFree(dev_ns_v_p);
    cudaFree(dev_ns_v_p_x);
    cudaFree(dev_ns_v_p_y);
    cudaFree(dev_ns_v_p_z);
    cudaFree(dev_ns_vp_avg);
    cudaFree(dev_ns_d_avg);
    cudaFree(dev_ns_fi);
    cudaFree(dev_ns_phi);
    cudaFree(dev_ns_dphi);
    cudaFree(dev_ns_div_phi_v_v);
    cudaFree(dev_ns_epsilon);
    cudaFree(dev_ns_epsilon_new);
    cudaFree(dev_ns_norm);
    cudaFree(dev_ns_f);
    cudaFree(dev_ns_f1);
    cudaFree(dev_ns_f2);
    cudaFree(dev_ns_tau);
    cudaFree(dev_ns_div_phi_vi_v);
    cudaFree(dev_ns_div_phi_tau);
}

// Transfer to device
void DEM::transferNStoGlobalDeviceMemory(int statusmsg)
{
    checkForCudaErrors("Before attempting cudaMemcpy in "
            "transferNStoGlobalDeviceMemory");

    //if (verbose == 1 && statusmsg == 1)
        //std::cout << "  Transfering fluid data to the device:           ";

    // memory size for a scalar field
    unsigned int memSizeF  = sizeof(Float)*NScells();

    //writeNSarray(ns.p, "ns.p.txt");

    cudaMemcpy(dev_ns_p, ns.p, memSizeF, cudaMemcpyHostToDevice);
    checkForCudaErrors("transferNStoGlobalDeviceMemory after first cudaMemcpy");
    cudaMemcpy(dev_ns_v, ns.v, memSizeF*3, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_ns_v_p, ns.v_p, memSizeF*3, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_ns_phi, ns.phi, memSizeF, cudaMemcpyHostToDevice);
    cudaMemcpy(dev_ns_dphi, ns.dphi, memSizeF, cudaMemcpyHostToDevice);

    checkForCudaErrors("End of transferNStoGlobalDeviceMemory");
    //if (verbose == 1 && statusmsg == 1)
        //std::cout << "Done" << std::endl;
}

// Transfer from device
void DEM::transferNSfromGlobalDeviceMemory(int statusmsg)
{
    if (verbose == 1 && statusmsg == 1)
        std::cout << "  Transfering fluid data from the device:         ";

    // memory size for a scalar field
    unsigned int memSizeF  = sizeof(Float)*NScells();

    cudaMemcpy(ns.p, dev_ns_p, memSizeF, cudaMemcpyDeviceToHost);
    cudaMemcpy(ns.v, dev_ns_v, memSizeF*3, cudaMemcpyDeviceToHost);
    cudaMemcpy(ns.v_p, dev_ns_v_p, memSizeF*3, cudaMemcpyDeviceToHost);
    cudaMemcpy(ns.phi, dev_ns_phi, memSizeF, cudaMemcpyDeviceToHost);
    cudaMemcpy(ns.dphi, dev_ns_dphi, memSizeF, cudaMemcpyDeviceToHost);
    cudaMemcpy(ns.norm, dev_ns_norm, memSizeF, cudaMemcpyDeviceToHost);

    checkForCudaErrors("End of transferNSfromGlobalDeviceMemory");
    if (verbose == 1 && statusmsg == 1)
        std::cout << "Done" << std::endl;
}

// Transfer the normalized residuals from device to host
void DEM::transferNSnormFromGlobalDeviceMemory()
{
    cudaMemcpy(ns.norm, dev_ns_norm, sizeof(Float)*NScells(),
            cudaMemcpyDeviceToHost);
    checkForCudaErrors("End of transferNSnormFromGlobalDeviceMemory");
}

// Transfer the pressure change from device to host
void DEM::transferNSepsilonFromGlobalDeviceMemory()
{
    cudaMemcpy(ns.epsilon, dev_ns_epsilon, sizeof(Float)*NScells(),
            cudaMemcpyDeviceToHost);
    checkForCudaErrors("End of transferNSepsilonFromGlobalDeviceMemory");
}

// Transfer the pressure change from device to host
void DEM::transferNSepsilonNewFromGlobalDeviceMemory()
{
    cudaMemcpy(ns.epsilon_new, dev_ns_epsilon_new, sizeof(Float)*NScells(),
            cudaMemcpyDeviceToHost);
    checkForCudaErrors("End of transferNSepsilonFromGlobalDeviceMemory");
}

// Get linear index from 3D grid position
__inline__ __device__ unsigned int idx(
        const int x, const int y, const int z)
{
    // without ghost nodes
    //return x + dev_grid.num[0]*y + dev_grid.num[0]*dev_grid.num[1]*z;

    // with ghost nodes
    // the ghost nodes are placed at x,y,z = -1 and WIDTH
    return (x+1) + (devC_grid.num[0]+2)*(y+1) +
        (devC_grid.num[0]+2)*(devC_grid.num[1]+2)*(z+1);
}

// Get linear index of velocity node from 3D grid position in staggered grid
__inline__ __device__ unsigned int vidx(
        const int x, const int y, const int z)
{
    return x + (devC_grid.num[0]+1)*y
        + (devC_grid.num[0]+1)*(devC_grid.num[1]+1)*z;
}

// Find averaged cell velocities from cell-face velocities. This function works
// for both normal and predicted velocities. Launch for every cell in the
// dev_ns_v or dev_ns_v_p array. This function does not set the averaged
// velocity values in the ghost node cells.
__global__ void findNSavgVel(
        Float3* dev_ns_v,    // out
        Float*  dev_ns_v_x,  // in
        Float*  dev_ns_v_y,  // in
        Float*  dev_ns_v_z)  // in
{

    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid
    if (x<devC_grid.num[0] && y<devC_grid.num[1] && z<devC_grid.num[2]-1) {
        const unsigned int cellidx = idx(x,y,z);

        // Read cell-face velocities
        __syncthreads();
        const Float v_xn = dev_ns_v_x[vidx(x,y,z)];
        const Float v_xp = dev_ns_v_x[vidx(x+1,y,z)];
        const Float v_yn = dev_ns_v_y[vidx(x,y,z)];
        const Float v_yp = dev_ns_v_y[vidx(x,y+1,z)];
        const Float v_zn = dev_ns_v_z[vidx(x,y,z)];
        const Float v_zp = dev_ns_v_z[vidx(x,y,z+1)];

        // Find average velocity using arithmetic means
        const Float3 v_bar = MAKE_FLOAT3(
                amean(v_xn, v_xp),
                amean(v_yn, v_yp),
                amean(v_zn, v_zp));

        // Save value
        __syncthreads();
        dev_ns_v[idx(x,y,z)] = v_bar;
    }
}

// Find cell-face velocities from averaged velocities. This function works for
// both normal and predicted velocities. Launch for every cell in the dev_ns_v
// or dev_ns_v_p array. Make sure that the averaged velocity ghost nodes are set
// beforehand.
__global__ void findNScellFaceVel(
        Float3* dev_ns_v,    // in
        Float*  dev_ns_v_x,  // out
        Float*  dev_ns_v_y,  // out
        Float*  dev_ns_v_z)  // out
{

    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && x < nz) {
        const unsigned int cellidx = idx(x,y,z);

        // Read the averaged velocity from this cell as well as the required
        // components from the neighbor cells
        __syncthreads();
        const Float3 v = dev_ns_v[idx(x,y,z)];
        const Float v_xn = dev_ns_v[idx(x-1,y,z)].x;
        const Float v_xp = dev_ns_v[idx(x+1,y,z)].x;
        const Float v_yn = dev_ns_v[idx(x,y-1,z)].y;
        const Float v_yp = dev_ns_v[idx(x,y+1,z)].y;
        const Float v_zn = dev_ns_v[idx(x,y,z-1)].z;
        const Float v_zp = dev_ns_v[idx(x,y,z+1)].z;

        // Find cell-face velocities and save them right away
        __syncthreads();

        // Values at the faces closest to the coordinate system origo
        dev_ns_v_x[vidx(x,y,z)] = amean(v_xn, v.x);
        dev_ns_v_y[vidx(x,y,z)] = amean(v_yn, v.y);
        dev_ns_v_z[vidx(x,y,z)] = amean(v_zn, v.z);

        // Values at the cell faces furthest from the coordinate system origo.
        // These values should only be written at the corresponding boundaries
        // in order to avoid write conflicts.
        if (x == nx-1)
            dev_ns_v_x[vidx(x+1,y,z)] = amean(v.x, v_xp);
        if (y == ny-1)
            dev_ns_v_x[vidx(x+1,y,z)] = amean(v.y, v_yp);
        if (z == nz-1)
            dev_ns_v_x[vidx(x+1,y,z)] = amean(v.z, v_zp);
    }
}


// Set the initial guess of the values of epsilon.
__global__ void setNSepsilonInterior(Float* dev_ns_epsilon, Float value)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] &&
            z > 0 && z < devC_grid.num[2]-1) {
        __syncthreads();
        const unsigned int cellidx = idx(x,y,z);
        dev_ns_epsilon[cellidx] = value;
    }
}

// The normalized residuals are given an initial value of 0, since the values at
// the Dirichlet boundaries aren't written during the iterations.
__global__ void setNSnormZero(Float* dev_ns_norm)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {
        __syncthreads();
        const unsigned int cellidx = idx(x,y,z);
        dev_ns_norm[idx(x,y,z)]    = 0.0;
    }
}


// Set the constant values of epsilon at the lower boundary.  Since the
// Dirichlet boundary values aren't transfered during array swapping, the values
// also need to be written to the new array of epsilons.  A value of 0 equals
// the Dirichlet boundary condition: the new value should be identical to the
// old value, i.e. the temporal gradient is 0
__global__ void setNSepsilonBottom(
        Float* dev_ns_epsilon,
        Float* dev_ns_epsilon_new,
        const Float value)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid, and at the z boundaries
    //if (x < devC_grid.num[0] && y < devC_grid.num[1] &&
    //        (z == devC_grid.num[2]-1 || z == 0)) {
    // check that we are not outside the fluid grid, and at the lower z boundary
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z == 0) {

        __syncthreads();
        const unsigned int cellidx = idx(x,y,z);
        dev_ns_epsilon[cellidx]     = value;
        dev_ns_epsilon_new[cellidx] = value;
    }
}

// Set the constant values of epsilon at the lower boundary.  Since the
// Dirichlet boundary values aren't transfered during array swapping, the values
// also need to be written to the new array of epsilons.  A value of 0 equals
// the Dirichlet boundary condition: the new value should be identical to the
// old value, i.e. the temporal gradient is 0
__global__ void setNSepsilonTop(
        Float* dev_ns_epsilon,
        Float* dev_ns_epsilon_new,
        const Float value)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid, and at the upper z boundary
    if (x < devC_grid.num[0] && y < devC_grid.num[1] &&
            z == devC_grid.num[2]-1) {

        __syncthreads();
        const unsigned int cellidx = idx(x,y,z);
        dev_ns_epsilon[cellidx]     = value;
        dev_ns_epsilon_new[cellidx] = value;
    }
}
__device__ void copyNSvalsDev(
        unsigned int read, unsigned int write,
        Float* dev_ns_p,
        Float3* dev_ns_v, Float3* dev_ns_v_p,
        Float* dev_ns_phi, Float* dev_ns_dphi,
        Float* dev_ns_epsilon)
{
    // Coalesced read
    const Float  p       = dev_ns_p[read];
    const Float3 v       = dev_ns_v[read];
    const Float3 v_p     = dev_ns_v_p[read];
    const Float  phi     = dev_ns_phi[read];
    const Float  dphi    = dev_ns_dphi[read];
    const Float  epsilon = dev_ns_epsilon[read];

    // Coalesced write
    __syncthreads();
    dev_ns_p[write]       = p;
    dev_ns_v[write]       = v;
    dev_ns_v_p[write]     = v_p;
    dev_ns_phi[write]     = phi;
    dev_ns_dphi[write]    = dphi;
    dev_ns_epsilon[write] = epsilon;
}


// Update ghost nodes from their parent cell values. The edge (diagonal) cells
// are not written since they are not read. Launch this kernel for all cells in
// the grid
__global__ void setNSghostNodesDev(
        Float* dev_ns_p,
        Float3* dev_ns_v, Float3* dev_ns_v_p,
        Float* dev_ns_phi, Float* dev_ns_dphi,
        Float* dev_ns_epsilon)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // 1D position of ghost node
    unsigned int writeidx;

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        if (x == 0) {
            writeidx = idx(nx,y,z);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }
        if (x == nx-1) {
            writeidx = idx(-1,y,z);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }

        if (y == 0) {
            writeidx = idx(x,ny,z);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }
        if (y == ny-1) {
            writeidx = idx(x,-1,z);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }

        // Z boundaries fixed
        if (z == 0) {
            writeidx = idx(x,y,-1);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }
        if (z == nz-1) {
            writeidx = idx(x,y,nz);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }

        // Z boundaries periodic
        /*if (z == 0) {
            writeidx = idx(x,y,nz);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }
        if (z == nz-1) {
            writeidx = idx(x,y,-1);
            copyNSvalsDev(cellidx, writeidx,
                    dev_ns_p,
                    dev_ns_v, dev_ns_v_p,
                    dev_ns_phi, dev_ns_dphi,
                    dev_ns_epsilon);
        }*/
    }
}

// Update a field in the ghost nodes from their parent cell values. The edge
// (diagonal) cells are not written since they are not read. Launch this kernel
// for all cells in the grid usind setNSghostNodes<datatype><<<.. , ..>>>( .. );
template<typename T>
__global__ void setNSghostNodes(T* dev_scalarfield)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        const T val = dev_scalarfield[idx(x,y,z)];

        if (x == 0)
            dev_scalarfield[idx(nx,y,z)] = val;
        if (x == nx-1)
            dev_scalarfield[idx(-1,y,z)] = val;

        if (y == 0)
            dev_scalarfield[idx(x,ny,z)] = val;
        if (y == ny-1)
            dev_scalarfield[idx(x,-1,z)] = val;

        if (z == 0)
            dev_scalarfield[idx(x,y,-1)] = val;     // Dirichlet
            //dev_scalarfield[idx(x,y,nz)] = val;    // Periodic -z
        if (z == nz-1)
            dev_scalarfield[idx(x,y,nz)] = val;     // Dirichlet
            //dev_scalarfield[idx(x,y,-1)] = val;    // Periodic +z
    }
}

// Update a field in the ghost nodes from their parent cell values. The edge
// (diagonal) cells are not written since they are not read.
template<typename T>
__global__ void setNSghostNodes(
        T* dev_scalarfield,
        int bc_bot,
        int bc_top)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        const T val = dev_scalarfield[idx(x,y,z)];

        // x
        if (x == 0)
            dev_scalarfield[idx(nx,y,z)] = val;
        if (x == nx-1)
            dev_scalarfield[idx(-1,y,z)] = val;

        // y
        if (y == 0)
            dev_scalarfield[idx(x,ny,z)] = val;
        if (y == ny-1)
            dev_scalarfield[idx(x,-1,z)] = val;

        // z
        if (z == 0 && bc_bot == 0)
            dev_scalarfield[idx(x,y,-1)] = val;     // Dirichlet
        if (z == 1 && bc_bot == 1)
            dev_scalarfield[idx(x,y,-1)] = val;     // Neumann
        if (z == 0 && bc_bot == 2)
            dev_scalarfield[idx(x,y,nz)] = val;     // Periodic -z

        if (z == nz-1 && bc_top == 0)
            dev_scalarfield[idx(x,y,nz)] = val;     // Dirichlet
        if (z == nz-2 && bc_top == 1)
            dev_scalarfield[idx(x,y,nz)] = val;     // Neumann
        if (z == nz-1 && bc_top == 2)
            dev_scalarfield[idx(x,y,-1)] = val;     // Periodic +z
    }
}

// Update the tensor field for the ghost nodes from their parent cell values.
// The edge (diagonal) cells are not written since they are not read. Launch
// this kernel for all cells in the grid.
__global__ void setNSghostNodes_tau(
        Float* dev_ns_tau,
        int bc_bot,
        int bc_top)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Linear index of length-6 vector field entry
        unsigned int cellidx6 = idx(x,y,z)*6;

        // Read parent values
        __syncthreads();
        const Float tau_xx = dev_ns_tau[cellidx6];
        const Float tau_xy = dev_ns_tau[cellidx6+1];
        const Float tau_xz = dev_ns_tau[cellidx6+2];
        const Float tau_yy = dev_ns_tau[cellidx6+3];
        const Float tau_yz = dev_ns_tau[cellidx6+4];
        const Float tau_zz = dev_ns_tau[cellidx6+5];

        // x
        if (x == 0) {
            cellidx6 = idx(nx,y,z)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (x == nx-1) {
            cellidx6 = idx(-1,y,z)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }

        // y
        if (y == 0) {
            cellidx6 = idx(x,ny,z)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (y == ny-1) {
            cellidx6 = idx(x,-1,z)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }

        // z
        if (z == 0 && bc_bot == 0) {  // Dirichlet
            cellidx6 = idx(x,y,-1)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (z == 1 && bc_bot == 1) {  // Neumann
            cellidx6 = idx(x,y,-1)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (z == 0 && bc_bot == 2) {  // Periodic
            cellidx6 = idx(x,y,nz)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }

        if (z == nz-1 && bc_top == 0) {  // Dirichlet
            cellidx6 = idx(x,y,nz)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (z == nz-2 && bc_top == 1) {  // Neumann
            cellidx6 = idx(x,y,nz)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
        if (z == nz-1 && bc_top == 2) {  // Periodic
            cellidx6 = idx(x,y,-1)*6;
            dev_ns_tau[cellidx6]   = tau_xx;
            dev_ns_tau[cellidx6+1] = tau_xy;
            dev_ns_tau[cellidx6+2] = tau_xz;
            dev_ns_tau[cellidx6+3] = tau_yy;
            dev_ns_tau[cellidx6+4] = tau_yz;
            dev_ns_tau[cellidx6+5] = tau_zz;
        }
    }
}

// Update a the forcing values in the ghost nodes from their parent cell values.
// The edge (diagonal) cells are not written since they are not read. Launch
// this kernel for all cells in the grid.
/*
__global__ void setNSghostNodesForcing(
        Float*  dev_ns_f1,
        Float3* dev_ns_f2,
        Float*  dev_ns_f,
        unsigned int nijac)

{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // 1D thread index
    unsigned int cellidx = idx(x,y,z);

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        __syncthreads();
        const Float f  = dev_ns_f[cellidx];
        Float  f1;
        Float3 f2;

        if (nijac == 0) {
            __syncthreads();
            f1 = dev_ns_f1[cellidx];
            f2 = dev_ns_f2[cellidx];
        }

        if (x == 0) {
            cellidx = idx(nx,y,z);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }
        if (x == nx-1) {
            cellidx = idx(-1,y,z);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }

        if (y == 0) {
            cellidx = idx(x,ny,z);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }
        if (y == ny-1) {
            cellidx = idx(x,-1,z);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }

        if (z == 0) {
            cellidx = idx(x,y,nz);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }
        if (z == nz-1) {
            cellidx = idx(x,y,-1);
            dev_ns_f[cellidx] = f;
            if (nijac == 0) {
                dev_ns_f1[cellidx] = f1;
                dev_ns_f2[cellidx] = f2;
            }
        }
    }
}
*/

// Find the porosity in each cell on the base of a sphere, centered at the cell
// center. 
__global__ void findPorositiesVelocitiesDiametersSpherical(
        unsigned int* dev_cellStart,
        unsigned int* dev_cellEnd,
        Float4* dev_x_sorted,
        Float4* dev_vel_sorted,
        Float*  dev_ns_phi,
        Float*  dev_ns_dphi,
        Float3* dev_ns_vp_avg,
        Float*  dev_ns_d_avg,
        unsigned int iteration)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;
    
    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell dimensions
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // Cell sphere radius
    const Float R = fmin(dx, fmin(dy,dz)) * 0.5;
    const Float cell_volume = 4.0/3.0*M_PI*R*R*R;

    Float void_volume = cell_volume;
    Float4 xr;  // particle pos. and radius

    // check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Cell sphere center position
        const Float3 X = MAKE_FLOAT3(
                x*dx + 0.5*dx,
                y*dy + 0.5*dy,
                z*dz + 0.5*dz);

        Float d, r;
        Float phi = 1.00;
        Float4 v;
        unsigned int n = 0;

        Float3 v_avg = MAKE_FLOAT3(0.0, 0.0, 0.0);
        Float  d_avg = 0.0;

        // Read old porosity
        __syncthreads();
        Float phi_0 = dev_ns_phi[idx(x,y,z)];

        // The cell 3d index
        const int3 gridPos = make_int3((int)x,(int)y,(int)z);

        // The neighbor cell 3d index
        int3 targetCell;

        // The distance modifier for particles across periodic boundaries
        Float3 dist, distmod;

        unsigned int cellID, startIdx, endIdx, i;

        // Iterate over 27 neighbor cells
        for (int z_dim=-1; z_dim<2; ++z_dim) { // z-axis
            for (int y_dim=-1; y_dim<2; ++y_dim) { // y-axis
                for (int x_dim=-1; x_dim<2; ++x_dim) { // x-axis

                    // Index of neighbor cell this iteration is looking at
                    targetCell = gridPos + make_int3(x_dim, y_dim, z_dim);

                    // Get distance modifier for interparticle
                    // vector, if it crosses a periodic boundary
                    distmod = MAKE_FLOAT3(0.0, 0.0, 0.0);
                    if (findDistMod(&targetCell, &distmod) != -1) {

                        // Calculate linear cell ID
                        cellID = targetCell.x + targetCell.y * devC_grid.num[0]
                            + (devC_grid.num[0] * devC_grid.num[1])
                            * targetCell.z; 

                        // Lowest particle index in cell
                        startIdx = dev_cellStart[cellID];

                        // Make sure cell is not empty
                        if (startIdx != 0xffffffff) {

                            // Highest particle index in cell
                            endIdx = dev_cellEnd[cellID];

                            // Iterate over cell particles
                            for (i=startIdx; i<endIdx; ++i) {

                                // Read particle position and radius
                                __syncthreads();
                                xr = dev_x_sorted[i];
                                v  = dev_vel_sorted[i];
                                r = xr.w;

                                // Find center distance
                                dist = MAKE_FLOAT3(
                                            X.x - xr.x, 
                                            X.y - xr.y,
                                            X.z - xr.z);
                                dist += distmod;
                                d = length(dist);

                                // Lens shaped intersection
                                if ((R - r) < d && d < (R + r)) {
                                    void_volume -=
                                        1.0/(12.0*d) * (
                                                M_PI*(R + r - d)*(R + r - d)
                                                *(d*d + 2.0*d*r - 3.0*r*r
                                                    + 2.0*d*R + 6.0*r*R
                                                    - 3.0*R*R) );
                                    v_avg += MAKE_FLOAT3(v.x, v.y, v.z);
                                    d_avg += 2.0*r;
                                    n++;
                                }

                                // Particle fully contained in cell sphere
                                if (d <= R - r) {
                                    void_volume -= 4.0/3.0*M_PI*r*r*r;
                                    v_avg += MAKE_FLOAT3(v.x, v.y, v.z);
                                    d_avg += 2.0*r;
                                    n++;
                                }
                            }
                        }
                    }
                }
            }
        }

        if (phi < 0.999) {
            v_avg /= n;
            d_avg /= n;
        }

        // Make sure that the porosity is in the interval [0.0;1.0]
        phi = fmin(1.00, fmax(0.00, void_volume/cell_volume));
        //phi = void_volume/cell_volume;

        Float dphi = phi - phi_0;
        if (iteration == 0)
            dphi = 0.0;

        // report values to stdout for debugging
        //printf("%d,%d,%d\tphi = %f dphi = %f v_avg = %f,%f,%f d_avg = %f\n",
         //       x,y,z, phi, dphi, v_avg.x, v_avg.y, v_avg.z, d_avg);

        // Save porosity, porosity change, average velocity and average diameter
        __syncthreads();
        //phi = 1.0; dphi = 0.0; // disable porosity effects
        const unsigned int cellidx = idx(x,y,z);
        dev_ns_phi[cellidx]  = phi;
        dev_ns_dphi[cellidx] = dphi;
        dev_ns_vp_avg[cellidx] = v_avg;
        dev_ns_d_avg[cellidx]  = d_avg;
    }
}

// Modulate the hydraulic pressure at the upper boundary
__global__ void setUpperPressureNS(
        Float* dev_ns_p,
        Float* dev_ns_epsilon,
        Float* dev_ns_epsilon_new,
        const Float new_pressure)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;
    
    // check that the thread is located at the top boundary
    if (x < devC_grid.num[0] &&
            y < devC_grid.num[1] &&
            z == devC_grid.num[2]-1) {

        const unsigned int cellidx = idx(x,y,z);

        // Read the current pressure
        const Float pressure = dev_ns_p[cellidx];

        // Determine the new epsilon boundary condition
        const Float epsilon = new_pressure - BETA*pressure;

        // Write the new pressure and epsilon values to the top boundary cells
        __syncthreads();
        dev_ns_epsilon[cellidx] = epsilon;
        dev_ns_epsilon_new[cellidx] = epsilon;
        dev_ns_p[cellidx] = new_pressure;
    }
}

// Find the gradient in a cell in a homogeneous, cubic 3D scalar field using
// finite central differences
__device__ Float3 gradient(
        const Float* dev_scalarfield,
        const unsigned int x,
        const unsigned int y,
        const unsigned int z,
        const Float dx,
        const Float dy,
        const Float dz)
{
    // Read 6 neighbor cells
    __syncthreads();
    //const Float p  = dev_scalarfield[idx(x,y,z)];
    const Float xn = dev_scalarfield[idx(x-1,y,z)];
    const Float xp = dev_scalarfield[idx(x+1,y,z)];
    const Float yn = dev_scalarfield[idx(x,y-1,z)];
    const Float yp = dev_scalarfield[idx(x,y+1,z)];
    const Float zn = dev_scalarfield[idx(x,y,z-1)];
    const Float zp = dev_scalarfield[idx(x,y,z+1)];

    //__syncthreads();
    //if (p != 0.0)
        //printf("p[%d,%d,%d] =\t%f\n", x,y,z, p);

    // Calculate central-difference gradients
    return MAKE_FLOAT3(
            (xp - xn)/(2.0*dx),
            (yp - yn)/(2.0*dy),
            (zp - zn)/(2.0*dz));
}

// Find the gradients of the velocity at the center of the cell with index x,y,z
// and cell size dx,dy,dz
__device__ Float3 v_gradient(
        const Float* dev_ns_v_x,
        const Float* dev_ns_v_y,
        const Float* dev_ns_v_z,
        const unsigned int x,
        const unsigned int y,
        const unsigned int z,
        const Float dx,
        const Float dy,
        const Float dz)
{
    // Read the six cell face velocities
    __syncthreads();
    const Float v_xn = dev_ns_v_x[vidx(x,y,z)];
    const Float v_xp = dev_ns_v_x[vidx(x+1,y,z)];
    const Float v_yn = dev_ns_v_y[vidx(x,y,z)];
    const Float v_yp = dev_ns_v_y[vidx(x,y+1,z)];
    const Float v_zn = dev_ns_v_z[vidx(x,y,z)];
    const Float v_zp = dev_ns_v_y[vidx(x,y,z+1)];

    // Calculate the velocity gradient
    return MAKE_FLOAT3(
            (v_xp - v_xn)/dx,
            (v_yp - v_yn)/dy,
            (v_zp - v_zn)/dz);
}

// Find the dv_i/di gradients in a cell in a homogeneous, cubic 3D vector field
// using finite central differences
__device__ Float3 gradient(
        const Float3* dev_vectorfield,
        const unsigned int x,
        const unsigned int y,
        const unsigned int z,
        const Float dx,
        const Float dy,
        const Float dz)
{
    // Read 6 neighbor cells
    __syncthreads();
    const Float xn = dev_vectorfield[idx(x-1,y,z)].x;
    const Float xp = dev_vectorfield[idx(x+1,y,z)].x;
    const Float yn = dev_vectorfield[idx(x,y-1,z)].y;
    const Float yp = dev_vectorfield[idx(x,y+1,z)].y;
    const Float zn = dev_vectorfield[idx(x,y,z-1)].z;
    const Float zp = dev_vectorfield[idx(x,y,z+1)].z;

    //__syncthreads();
    //if (p != 0.0)
        //printf("p[%d,%d,%d] =\t%f\n", x,y,z, p);

    // Calculate central-difference gradients
    return MAKE_FLOAT3(
            (xp - xn)/(2.0*dx),
            (yp - yn)/(2.0*dy),
            (zp - zn)/(2.0*dz));
}

// Find the divergence in a cell in a homogeneous, cubic, 3D vector field
__device__ Float divergence(
        const Float3* dev_vectorfield,
        const unsigned int x,
        const unsigned int y,
        const unsigned int z,
        const Float dx,
        const Float dy,
        const Float dz)
{
    // Read 6 neighbor cells
    __syncthreads();
    const Float3 xn = dev_vectorfield[idx(x-1,y,z)];
    const Float3 xp = dev_vectorfield[idx(x+1,y,z)];
    const Float3 yn = dev_vectorfield[idx(x,y-1,z)];
    const Float3 yp = dev_vectorfield[idx(x,y+1,z)];
    const Float3 zn = dev_vectorfield[idx(x,y,z-1)];
    const Float3 zp = dev_vectorfield[idx(x,y,z+1)];

    // Calculate the central-difference gradients and divergence
    return
        (xp.x - xn.x)/(2.0*dx) +
        (yp.y - yn.y)/(2.0*dy) +
        (zp.z - zn.z)/(2.0*dz);
}

// Find the spatial gradient in e.g. pressures per cell
// using first order central differences
__global__ void findNSgradientsDev(
        Float* dev_scalarfield,     // in
        Float3* dev_vectorfield)    // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Grid sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        const Float3 grad = gradient(dev_scalarfield, x, y, z, dx, dy, dz);

        // Write gradient
        __syncthreads();
        dev_vectorfield[cellidx] = grad;
    }
}

// Find the outer product of v v
__global__ void findvvOuterProdNS(
        Float3* dev_ns_v,       // in
        Float*  dev_ns_v_prod)  // out
{
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // 1D thread index
    const unsigned int cellidx6 = idx(x,y,z)*6;

    // Check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

        __syncthreads();
        const Float3 v = dev_ns_v[idx(x,y,z)];

        // The outer product (v v) looks like:
        // [[ v_x^2    v_x*v_y  v_x*v_z ]
        //  [ v_y*v_x  v_y^2    v_y*v_z ]
        //  [ v_z*v_x  v_z*v_y  v_z^2   ]]

        // The tensor is symmetrical: value i,j = j,i.
        // Only the upper triangle is saved, with the cells given a linear index
        // enumerated as:
        // [[ 0 1 2 ]
        //  [   3 4 ]
        //  [     5 ]]

        __syncthreads();
        dev_ns_v_prod[cellidx6]   = v.x*v.x;
        dev_ns_v_prod[cellidx6+1] = v.x*v.y;
        dev_ns_v_prod[cellidx6+2] = v.x*v.z;
        dev_ns_v_prod[cellidx6+3] = v.y*v.y;
        dev_ns_v_prod[cellidx6+4] = v.y*v.z;
        dev_ns_v_prod[cellidx6+5] = v.z*v.z;
    }
}


// Find the fluid stress tensor. It is symmetrical, and can thus be saved in 6
// values in 3D.
__global__ void findNSstressTensor(
        Float3* dev_ns_v,       // in
        Float*  dev_ns_tau)     // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx6 = idx(x,y,z)*6;

    // Check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

        // The fluid stress tensor (tau) looks like
        // [[ tau_xx  tau_xy  tau_xz ]
        //  [ tau_yx  tau_xy  tau_yz ]
        //  [ tau_zx  tau_zy  tau_zz ]]

        // The tensor is symmetrical: value i,j = j,i.
        // Only the upper triangle is saved, with the cells given a linear index
        // enumerated as:
        // [[ 0 1 2 ]
        //  [   3 4 ]
        //  [     5 ]]

        // Read neighbor values for central differences
        __syncthreads();
        const Float3 xp = dev_ns_v[idx(x+1,y,z)];
        const Float3 xn = dev_ns_v[idx(x-1,y,z)];
        const Float3 yp = dev_ns_v[idx(x,y+1,z)];
        const Float3 yn = dev_ns_v[idx(x,y-1,z)];
        const Float3 zp = dev_ns_v[idx(x,y,z+1)];
        const Float3 zn = dev_ns_v[idx(x,y,z-1)];

        // Fluid viscosity
        const Float nu = devC_params.nu;

        // The diagonal stress tensor components
        const Float tau_xx = 2.0*nu*(xp.x - xn.x)/(2.0*dx);
        const Float tau_yy = 2.0*nu*(yp.y - yn.y)/(2.0*dy);
        const Float tau_zz = 2.0*nu*(zp.z - zn.z)/(2.0*dz);

        // The off-diagonal stress tensor components
        const Float tau_xy =
            nu*((yp.x - yn.x)/(2.0*dy) + (xp.y - xn.y)/(2.0*dx));
        const Float tau_xz =
            nu*((zp.x - zn.x)/(2.0*dz) + (xp.z - xn.z)/(2.0*dx));
        const Float tau_yz =
            nu*((zp.y - zn.y)/(2.0*dz) + (yp.z - yn.z)/(2.0*dy));

        /*
        if (x == 0 && y == 0 && z == 0)
            printf("nu = %f\n", nu);
        if (tau_xz > 1.0e-6)
            printf("%d,%d,%d\ttau_xx = %f\n", x,y,z, tau_xx);
        if (tau_yz > 1.0e-6)
            printf("%d,%d,%d\ttau_yy = %f\n", x,y,z, tau_yy);
        if (tau_zz > 1.0e-6)
            printf("%d,%d,%d\ttau_zz = %f\n", x,y,z, tau_zz);
            */

        // Store values in global memory
        __syncthreads();
        dev_ns_tau[cellidx6]   = tau_xx;
        dev_ns_tau[cellidx6+1] = tau_xy;
        dev_ns_tau[cellidx6+2] = tau_xz;
        dev_ns_tau[cellidx6+3] = tau_yy;
        dev_ns_tau[cellidx6+4] = tau_yz;
        dev_ns_tau[cellidx6+5] = tau_zz;
    }
}


// Find the divergence of phi*v*v
__global__ void findNSdivphiviv(
        Float*  dev_ns_phi,          // in
        Float3* dev_ns_v,            // in
        Float3* dev_ns_div_phi_vi_v) // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Read porosity and velocity in the 6 neighbor cells
        __syncthreads();
        const Float  phi_xp = dev_ns_phi[idx(x+1,y,z)];
        const Float  phi_xn = dev_ns_phi[idx(x-1,y,z)];
        const Float  phi_yp = dev_ns_phi[idx(x,y+1,z)];
        const Float  phi_yn = dev_ns_phi[idx(x,y-1,z)];
        const Float  phi_zp = dev_ns_phi[idx(x,y,z+1)];
        const Float  phi_zn = dev_ns_phi[idx(x,y,z-1)];

        const Float3 v_xp = dev_ns_v[idx(x+1,y,z)];
        const Float3 v_xn = dev_ns_v[idx(x-1,y,z)];
        const Float3 v_yp = dev_ns_v[idx(x,y+1,z)];
        const Float3 v_yn = dev_ns_v[idx(x,y-1,z)];
        const Float3 v_zp = dev_ns_v[idx(x,y,z+1)];
        const Float3 v_zn = dev_ns_v[idx(x,y,z-1)];

        // Calculate the divergence: div(phi*v_i*v)
        const Float3 div_phi_vi_v = MAKE_FLOAT3(
                // x
                (phi_xp*v_xp.x*v_xp.x - phi_xn*v_xn.x*v_xn.x)/(2.0*dx) +
                (phi_yp*v_yp.x*v_yp.y - phi_yn*v_yn.x*v_yn.y)/(2.0*dy) +
                (phi_zp*v_zp.x*v_zp.z - phi_zn*v_zn.x*v_zn.z)/(2.0*dz),
                // y
                (phi_xp*v_xp.y*v_xp.x - phi_xn*v_xn.y*v_xn.x)/(2.0*dx) +
                (phi_yp*v_yp.y*v_yp.y - phi_yn*v_yn.y*v_yn.y)/(2.0*dy) +
                (phi_zp*v_zp.y*v_zp.z - phi_zn*v_zn.y*v_zn.z)/(2.0*dz),
                // z
                (phi_xp*v_xp.z*v_xp.x - phi_xn*v_xn.z*v_xn.x)/(2.0*dx) +
                (phi_yp*v_yp.z*v_yp.y - phi_yn*v_yn.z*v_yn.y)/(2.0*dy) +
                (phi_zp*v_zp.z*v_zp.z - phi_zn*v_zn.z*v_zn.z)/(2.0*dz));

        // Write divergence
        __syncthreads();
        dev_ns_div_phi_vi_v[cellidx] = div_phi_vi_v;
    }
}

// Find the divergence of phi*tau
__global__ void findNSdivphitau(
        Float*  dev_ns_phi,          // in
        Float*  dev_ns_tau,          // in
        Float3* dev_ns_div_phi_tau)  // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Read the porosity in the 6 neighbor cells
        __syncthreads();
        const Float phi_xp = dev_ns_phi[idx(x+1,y,z)];
        const Float phi_xn = dev_ns_phi[idx(x-1,y,z)];
        const Float phi_yp = dev_ns_phi[idx(x,y+1,z)];
        const Float phi_yn = dev_ns_phi[idx(x,y-1,z)];
        const Float phi_zp = dev_ns_phi[idx(x,y,z+1)];
        const Float phi_zn = dev_ns_phi[idx(x,y,z-1)];

        // Read the stress tensor in the 6 neighbor cells
        const Float tau_xx_xp = dev_ns_tau[idx(x+1,y,z)*6];
        const Float tau_xy_xp = dev_ns_tau[idx(x+1,y,z)*6+1];
        const Float tau_xz_xp = dev_ns_tau[idx(x+1,y,z)*6+2];
        const Float tau_yy_xp = dev_ns_tau[idx(x+1,y,z)*6+3];
        const Float tau_yz_xp = dev_ns_tau[idx(x+1,y,z)*6+4];
        const Float tau_zz_xp = dev_ns_tau[idx(x+1,y,z)*6+5];

        const Float tau_xx_xn = dev_ns_tau[idx(x-1,y,z)*6];
        const Float tau_xy_xn = dev_ns_tau[idx(x-1,y,z)*6+1];
        const Float tau_xz_xn = dev_ns_tau[idx(x-1,y,z)*6+2];
        const Float tau_yy_xn = dev_ns_tau[idx(x-1,y,z)*6+3];
        const Float tau_yz_xn = dev_ns_tau[idx(x-1,y,z)*6+4];
        const Float tau_zz_xn = dev_ns_tau[idx(x-1,y,z)*6+5];

        const Float tau_xx_yp = dev_ns_tau[idx(x,y+1,z)*6];
        const Float tau_xy_yp = dev_ns_tau[idx(x,y+1,z)*6+1];
        const Float tau_xz_yp = dev_ns_tau[idx(x,y+1,z)*6+2];
        const Float tau_yy_yp = dev_ns_tau[idx(x,y+1,z)*6+3];
        const Float tau_yz_yp = dev_ns_tau[idx(x,y+1,z)*6+4];
        const Float tau_zz_yp = dev_ns_tau[idx(x,y+1,z)*6+5];

        const Float tau_xx_yn = dev_ns_tau[idx(x,y-1,z)*6];
        const Float tau_xy_yn = dev_ns_tau[idx(x,y-1,z)*6+1];
        const Float tau_xz_yn = dev_ns_tau[idx(x,y-1,z)*6+2];
        const Float tau_yy_yn = dev_ns_tau[idx(x,y-1,z)*6+3];
        const Float tau_yz_yn = dev_ns_tau[idx(x,y-1,z)*6+4];
        const Float tau_zz_yn = dev_ns_tau[idx(x,y-1,z)*6+5];

        const Float tau_xx_zp = dev_ns_tau[idx(x,y,z+1)*6];
        const Float tau_xy_zp = dev_ns_tau[idx(x,y,z+1)*6+1];
        const Float tau_xz_zp = dev_ns_tau[idx(x,y,z+1)*6+2];
        const Float tau_yy_zp = dev_ns_tau[idx(x,y,z+1)*6+3];
        const Float tau_yz_zp = dev_ns_tau[idx(x,y,z+1)*6+4];
        const Float tau_zz_zp = dev_ns_tau[idx(x,y,z+1)*6+5];

        const Float tau_xx_zn = dev_ns_tau[idx(x,y,z-1)*6];
        const Float tau_xy_zn = dev_ns_tau[idx(x,y,z-1)*6+1];
        const Float tau_xz_zn = dev_ns_tau[idx(x,y,z-1)*6+2];
        const Float tau_yy_zn = dev_ns_tau[idx(x,y,z-1)*6+3];
        const Float tau_yz_zn = dev_ns_tau[idx(x,y,z-1)*6+4];
        const Float tau_zz_zn = dev_ns_tau[idx(x,y,z-1)*6+5];

        // Calculate div(phi*tau)
        const Float3 div_phi_tau = MAKE_FLOAT3(
                // x
                (phi_xp*tau_xx_xp - phi_xn*tau_xx_xn)/dx +
                (phi_yp*tau_xy_yp - phi_yn*tau_xy_yn)/dy +
                (phi_zp*tau_xz_zp - phi_zn*tau_xz_zn)/dz,
                // y
                (phi_xp*tau_xy_xp - phi_xn*tau_xy_xn)/dx +
                (phi_yp*tau_yy_yp - phi_yn*tau_yy_yn)/dy +
                (phi_zp*tau_yz_zp - phi_zn*tau_yz_zn)/dz,
                // z
                (phi_xp*tau_xz_xp - phi_xn*tau_xz_xn)/dx +
                (phi_yp*tau_yz_yp - phi_yn*tau_yz_yn)/dy +
                (phi_zp*tau_zz_zp - phi_zn*tau_zz_zn)/dz);

        // Write divergence
        __syncthreads();
        dev_ns_div_phi_tau[cellidx] = div_phi_tau;
    }
}

// Find the divergence of phi v v
__global__ void findNSdivphivv(
        Float*  dev_ns_v_prod, // in
        Float*  dev_ns_phi,    // in
        Float3* dev_ns_div_phi_v_v) // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Read cell and 6 neighbor cells
        __syncthreads();
        //const Float  phi    = dev_ns_phi[cellidx];
        const Float  phi_xp = dev_ns_phi[idx(x+1,y,z)];
        const Float  phi_xn = dev_ns_phi[idx(x-1,y,z)];
        const Float  phi_yp = dev_ns_phi[idx(x,y+1,z)];
        const Float  phi_yn = dev_ns_phi[idx(x,y-1,z)];
        const Float  phi_zp = dev_ns_phi[idx(x,y,z+1)];
        const Float  phi_zn = dev_ns_phi[idx(x,y,z-1)];

        // The tensor is symmetrical: value i,j = j,i.
        // Only the upper triangle is saved, with the cells given a linear index
        // enumerated as:
        // [[ 0 1 2 ]
        //  [   3 4 ]
        //  [     5 ]]

        // div(T) = 
        //  [ de_xx/dx + de_xy/dy + de_xz/dz ,
        //    de_yx/dx + de_yy/dy + de_yz/dz ,
        //    de_zx/dx + de_zy/dy + de_zz/dz ]

        // This function finds the divergence of (phi v v), which is a vector

        // Calculate the divergence. See
        // https://en.wikipedia.org/wiki/Divergence#Application_in_Cartesian_coordinates
        // The symmetry described in findvvOuterProdNS is used
        __syncthreads();
        const Float3 div = MAKE_FLOAT3(
                ((dev_ns_v_prod[idx(x+1,y,z)*6]*phi_xp
                  - dev_ns_v_prod[idx(x-1,y,z)*6]*phi_xn)/(2.0*dx) +
                 (dev_ns_v_prod[idx(x,y+1,z)*6+1]*phi_yp
                  - dev_ns_v_prod[idx(x,y-1,z)*6+1]*phi_yn)/(2.0*dy) +
                 (dev_ns_v_prod[idx(x,y,z+1)*6+2]*phi_zp
                  - dev_ns_v_prod[idx(x,y,z-1)*6+2]*phi_zn)/(2.0*dz)),
                ((dev_ns_v_prod[idx(x+1,y,z)*6+1]*phi_xp
                  - dev_ns_v_prod[idx(x-1,y,z)*6+1]*phi_xn)/(2.0*dx) +
                 (dev_ns_v_prod[idx(x,y+1,z)*6+3]*phi_yp
                  - dev_ns_v_prod[idx(x,y-1,z)*6+3]*phi_yn)/(2.0*dy) +
                 (dev_ns_v_prod[idx(x,y,z+1)*6+4]*phi_zp
                  - dev_ns_v_prod[idx(x,y,z-1)*6+4]*phi_zn)/(2.0*dz)),
                ((dev_ns_v_prod[idx(x+1,y,z)*6+2]*phi_xp
                  - dev_ns_v_prod[idx(x-1,y,z)*6+2]*phi_xn)/(2.0*dx) +
                 (dev_ns_v_prod[idx(x,y+1,z)*6+4]*phi_yp
                  - dev_ns_v_prod[idx(x,y-1,z)*6+4]*phi_yn)/(2.0*dy) +
                 (dev_ns_v_prod[idx(x,y,z+1)*6+5]*phi_zp
                  - dev_ns_v_prod[idx(x,y,z-1)*6+5]*phi_zn)/(2.0*dz)) );

        //printf("div[%d,%d,%d] = %f\t%f\t%f\n", x, y, z, div.x, div.y, div.z);

        // Write divergence
        __syncthreads();
        dev_ns_div_phi_v_v[cellidx] = div;
    }
}


// Find predicted fluid velocity
__global__ void findPredNSvelocities(
        Float*  dev_ns_p,               // in
        Float3* dev_ns_v,               // in
        Float*  dev_ns_phi,             // in
        Float*  dev_ns_dphi,            // in
        Float3* dev_ns_div_phi_vi_v,    // in
        Float3* dev_ns_div_phi_tau,     // in
        Float   rho,                    // in
        int     bc_bot,                 // in
        int     bc_top,                 // in
        Float3* dev_ns_fi,              // in
        Float3* dev_ns_v_p)             // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Values that are needed for calculating the predicted velocity
        __syncthreads();
        const Float3 v            = dev_ns_v[cellidx];
        const Float  phi          = dev_ns_phi[cellidx];
        const Float  dphi         = dev_ns_dphi[cellidx];
        const Float3 div_phi_vi_v = dev_ns_div_phi_vi_v[cellidx];
        const Float3 div_phi_tau  = dev_ns_div_phi_tau[cellidx];

        // The particle-fluid interaction force should only be incoorporated if
        // there is a fluid viscosity
        Float3 f_i;
        if (devC_params.nu > 0.0)
            f_i = dev_ns_fi[cellidx];
        else
            f_i = MAKE_FLOAT3(0.0, 0.0, 0.0);

        // Gravitational drag force on cell fluid mass
        //const Float3 g = MAKE_FLOAT3(0.0, 0.0, -10.0);
        //const Float3 f_g = rho*dx*dy*dz*phi*g;
        const Float3 f_g
            = MAKE_FLOAT3(devC_params.g[0], devC_params.g[1], devC_params.g[2])
            * rho * dx*dy*dz * phi;
        //const Float3 f_g = MAKE_FLOAT3(0.0, 0.0, 0.0);

        // Find pressure gradient
        Float3 grad_p = MAKE_FLOAT3(0.0, 0.0, 0.0);

        // The pressure gradient is not needed in Chorin's projection method
        // (BETA=0), so only has to be looked up in pressure-dependant
        // projection methods
        if (BETA > 0.0)
            grad_p = gradient(dev_ns_p, x, y, z, dx, dy, dz);

        // Calculate the predicted velocity
        Float3 v_p = v
            - BETA/rho*grad_p*devC_dt/phi
            + 1.0/rho*div_phi_tau*devC_dt/phi
            //+ devC_dt*(f_g - f_i)
            + devC_dt*(-1.0*f_i)
            - v*dphi/phi
            - div_phi_vi_v*devC_dt/phi;

        // Report velocity components to stdout for debugging
        /*const Float3 dv_pres = -BETA/rho*grad_p*devC_dt/phi;
        const Float3 dv_diff = 1.0/rho*div_phi_tau*devC_dt/phi;
        const Float3 dv_f = devC_dt*f_g;
        const Float3 dv_dphi = -1.0*v*dphi/phi;
        const Float3 dv_adv = -1.0*div_phi_vi_v*devC_dt/phi;
        printf("[%d,%d,%d]\tv_p = %f\t%f\t%f\tdv_pres = %f\t%f\t%f\t"
                "dv_diff = %f\t%f\t%f\tdv_f = %f\t%f\t%f\tv_dphi = %f\t%f\t%f\t"
                "dv_adv = %f\t%f\t%f\n",
                x, y, z, v_p.x, v_p.y, v_p.z,
                dv_pres.x, dv_pres.y, dv_pres.z,
                dv_diff.x, dv_diff.y, dv_diff.z,
                dv_f.x, dv_f.y, dv_f.z,
                dv_dphi.x, dv_dphi.y, dv_dphi.z,
                dv_adv.x, dv_adv.y, dv_adv.z);*/

        // Enforce no-flow BC if specified
        if ((z == 0 && bc_bot == 1) || (z == nz-1 && bc_top == 1))
            v_p.z = v.z;

        // Save the predicted velocity
        __syncthreads();
        dev_ns_v_p[cellidx] = v_p;
    }
}

// Find the value of the forcing function. Only grad(epsilon) changes during
// the Jacobi iterations. The remaining, constant terms are only calculated
// during the first iteration.
// The forcing function is:
//   f = (div(v_p)*rho)/dt
//     + (grad(phi) dot v_p*rho)/(dt*phi)
//     + (dphi*rho)/(dt*dt*phi)
//     - (grad(phi) dot grad(epsilon))/phi
// The following is calculated in the first Jacobi iteration and saved:
//   f1 = (div(v_p)*rho)/dt
//      + (grad(phi) dot v_p*rho)/(dt*phi)
//      + (dphi*rho)/(dt*dt*phi)
//   f2 = grad(phi)/phi
// At each iteration, the value of the forcing function is found as:
//   f = f1 - f2 dot grad(epsilon)
__global__ void findNSforcing(
        Float*  dev_ns_epsilon,
        Float*  dev_ns_f1,
        Float3* dev_ns_f2,
        Float*  dev_ns_f,
        Float*  dev_ns_phi,
        Float*  dev_ns_dphi,
        Float3* dev_ns_v_p,
        Float   rho,
        unsigned int nijac)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);


    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Constant forcing function terms
        Float f1;
        Float3 f2;

        // Check if this is the first Jacobi iteration. If it is, find f1 and f2
        if (nijac == 0) {

            // Read needed values
            __syncthreads();
            const Float3 v_p  = dev_ns_v_p[cellidx];
            const Float  phi  = dev_ns_phi[cellidx];
            const Float  dphi = dev_ns_dphi[cellidx];

            // Calculate derivatives
            const Float  div_v_p
                = divergence(dev_ns_v_p, x, y, z, dx, dy, dz);
            const Float3 grad_phi
                = gradient(dev_ns_phi, x, y, z, dx, dy, dz);

            // Find forcing function coefficients
            //f1 = 0.0;
            f1 = div_v_p*rho/devC_dt
                + dot(grad_phi, v_p)*rho/(devC_dt*phi)
                + dphi*rho/(devC_dt*devC_dt*phi);
            f2 = grad_phi/phi;

            // Report values terms in the forcing function for debugging
            /*
            const Float f1t1 = div_v_p*rho/devC_dt;
            const Float f1t2 = dot(grad_phi, v_p)*rho/(devC_dt*phi);
            const Float f1t3 = dphi*rho/(devC_dt*devC_dt*phi);
            printf("[%d,%d,%d] f1 = %f\t"
                    "f1t1 = %f\tf1t2 = %f\tf1t3 = %f\tf2 = %f\n",
                    x,y,z, f1, f1t1, f1t2, f1t3, f2);
            printf("[%d,%d,%d] v_p = %f\tdiv_v_p = %f\tgrad_phi = %f,%f,%f\t"
                    "phi = %f\tdphi = %f\n",
                    x,y,z, v_p, div_v_p, grad_phi.x, grad_phi.y, grad_phi.z,
                    phi, dphi);

            const Float phi_xn = dev_ns_phi[idx(x-1,y,z)];
            const Float phi_xp = dev_ns_phi[idx(x+1,y,z)];
            const Float phi_yn = dev_ns_phi[idx(x,y-1,z)];
            const Float phi_yp = dev_ns_phi[idx(x,y+1,z)];
            const Float phi_zn = dev_ns_phi[idx(x,y,z-1)];
            const Float phi_zp = dev_ns_phi[idx(x,y,z+1)];

            printf("[%d,%d,%d] phi: "
                    "xn = %f\t"
                    "xp = %f\t"
                    "yn = %f\t"
                    "yp = %f\t"
                    "zn = %f\t"
                    "zp = %f\n",
                    x,y,z, phi_xn, phi_xp, phi_yn, phi_yp, phi_zn, phi_zp);*/


            // Save values
            __syncthreads();
            dev_ns_f1[cellidx] = f1;
            dev_ns_f2[cellidx] = f2;

        } else {

            // Read previously found values
            __syncthreads();
            f1 = dev_ns_f1[cellidx];
            f2 = dev_ns_f2[cellidx];
        }

        // Find the gradient of epsilon, which changes during Jacobi iterations
        // TODO: Should the gradient of epsilon also be fixed according to BC's
        // here?
        const Float3 grad_epsilon
            = gradient(dev_ns_epsilon, x, y, z, dx, dy, dz);

        // Forcing function value
        const Float f = f1 - dot(f2, grad_epsilon);
        //printf("[%d,%d,%d]\tf1 = %f\tf2 = %f\tf = %f\n", x,y,z, f1, f2, f);

        // Save forcing function value
        __syncthreads();
        dev_ns_f[cellidx] = f;
    }
}

// Perform a single Jacobi iteration
__global__ void jacobiIterationNS(
        Float* dev_ns_epsilon,
        Float* dev_ns_epsilon_new,
        Float* dev_ns_norm,
        Float* dev_ns_f)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    //if (x < nx && y < ny && z < nz) {

    // internal nodes only
    //if (x > 0 && x < nx-1 && y > 0 && y < ny-1 && z > 0 && z < nz-1) {

    // Perform the epsilon updates for all non-ghost nodes except the Dirichlet
    // boundaries at z=0 and z=nz-1
    if (x < nx && y < ny && z > 0 && z < nz-1) {

    // Lower boundary: Neumann. Upper boundary: Dirichlet
    //if (x < nx && y < ny && z < nz-1) {

        // Read the epsilon values from the cell and its 6 neighbors
        __syncthreads();
        const Float e    = dev_ns_epsilon[cellidx];
        const Float e_xn = dev_ns_epsilon[idx(x-1,y,z)];
        const Float e_xp = dev_ns_epsilon[idx(x+1,y,z)];
        const Float e_yn = dev_ns_epsilon[idx(x,y-1,z)];
        const Float e_yp = dev_ns_epsilon[idx(x,y+1,z)];
        const Float e_zn = dev_ns_epsilon[idx(x,y,z-1)];
        const Float e_zp = dev_ns_epsilon[idx(x,y,z+1)];

        // Read the value of the forcing function
        const Float f = dev_ns_f[cellidx];
        //const Float f = 0.0;

        // New value of epsilon in 3D update, derived by rearranging the
        // discrete Laplacian
        const Float dxdx = dx*dx;
        const Float dydy = dy*dy;
        const Float dzdz = dz*dz;
        const Float e_new
            = (-dxdx*dydy*dzdz*f
                    + dydy*dzdz*(e_xn + e_xp)
                    + dxdx*dzdz*(e_yn + e_yp)
                    + dxdx*dydy*(e_zn + e_zp))
            /(2.0*(dxdx*dydy + dxdx*dzdz + dydy*dzdz));

        // New value of epsilon in 1D update
        //const Float e_new = (e_zp + e_zn - dz*dz*f)/2.0;

        // Print values for debugging
        /*printf("[%d,%d,%d]\t e = %f\tf = %f\te_new = %f\n",
                x,y,z, e, f, e_new);*/

        // Find the normalized residual value. A small value is added to the
        // denominator to avoid a divide by zero.
        const Float res_norm = (e_new - e)*(e_new - e)/(e_new*e_new + 1.0e-16);

        // Write results, apply relaxation parameter THETA to epsilon solution
        __syncthreads();
        //dev_ns_epsilon_new[cellidx] = e_new;
        dev_ns_epsilon_new[cellidx] = e*(1.0-THETA) + e_new*THETA;
        dev_ns_norm[cellidx] = res_norm;
    }
}

// Copy all values from one array to the other
template<typename T>
__global__ void copyValues(
        T* dev_read,
        T* dev_write)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Internal nodes only
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

    // Internal nodes + ghost nodes
    /*if (x <= devC_grid.num[0]+1 &&
            y <= devC_grid.num[1]+1 &&
            z <= devC_grid.num[2]+1) {*/

        const unsigned int cellidx = idx(x,y,z); // without ghost nodes
        //const unsigned int cellidx = idx(x-1,y-1,z-1); // with ghost nodes

        // Read
        __syncthreads();
        const T val = dev_read[cellidx];

        //if (z == devC_grid.num[2]-1)
            //printf("[%d,%d,%d] = %f\n", x, y, z, val);

        // Write
        __syncthreads();
        dev_write[cellidx] = val;
    }
}

// Computes the new velocity and pressure using the corrector
__global__ void updateNSvelocityPressure(
        Float*  dev_ns_p,
        Float3* dev_ns_v,
        Float3* dev_ns_v_p,
        Float*  dev_ns_epsilon,
        Float   rho,
        int     bc_bot,
        int     bc_top)
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Grid dimensions
    const unsigned int nx = devC_grid.num[0];
    const unsigned int ny = devC_grid.num[1];
    const unsigned int nz = devC_grid.num[2];

    // Cell sizes
    const Float dx = devC_grid.L[0]/nx;
    const Float dy = devC_grid.L[1]/ny;
    const Float dz = devC_grid.L[2]/nz;

    // 1D thread index
    const unsigned int cellidx = idx(x,y,z);

    // Check that we are not outside the fluid grid
    if (x < nx && y < ny && z < nz) {

        // Read values
        __syncthreads();
        const Float  p_old   = dev_ns_p[cellidx];
        const Float  epsilon = dev_ns_epsilon[cellidx];
        const Float3 v_p     = dev_ns_v_p[cellidx];

        // New pressure
        Float p = BETA*p_old + epsilon;

        // Find corrector gradient
        const Float3 grad_epsilon
            = gradient(dev_ns_epsilon, x, y, z, dx, dy, dz);

        // Find new velocity
        Float3 v = v_p - devC_dt/rho*grad_epsilon;

        // Print values for debugging
        /* if (z == 0) {
            Float e_up = dev_ns_epsilon[idx(x,y,z+1)];
            Float e_down = dev_ns_epsilon[idx(x,y,z-1)];
            printf("[%d,%d,%d]\tgrad_e = %f,%f,%f\te_up = %f\te_down = %f\n",
                    x,y,z,
                    grad_epsilon.x,
                    grad_epsilon.y,
                    grad_epsilon.z,
                    e_up,
                    e_down);
        }*/

        //if ((z == 0 && bc_bot == 1) || (z == nz-1 && bc_top == 1))
            //v.z = 0.0;

        // Write new values
        __syncthreads();
        dev_ns_p[cellidx] = p;
        //dev_ns_p[cellidx] = epsilon;
        dev_ns_v[cellidx] = v;
    }
}

// Find the average particle diameter and velocity for each CFD cell.
// UNUSED: The values are estimated in the porosity estimation function instead
__global__ void findAvgParticleVelocityDiameter(
        unsigned int* dev_cellStart, // in
        unsigned int* dev_cellEnd,   // in
        Float4* dev_vel_sorted,      // in
        Float4* dev_x_sorted,        // in
        Float3* dev_ns_vp_avg,       // out
        Float*  dev_ns_d_avg)        // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

        Float4 v;
        Float d;
        unsigned int startIdx, endIdx, i;
        unsigned int n = 0;

        // average particle velocity
        Float3 v_avg = MAKE_FLOAT3(0.0, 0.0, 0.0);  

        // average particle diameter
        Float d_avg = 0.0;

        const unsigned int cellID = x + y * devC_grid.num[0]
            + (devC_grid.num[0] * devC_grid.num[1]) * z; 

        // Lowest particle index in cell
        startIdx = dev_cellStart[cellID];

        // Make sure cell is not empty
        if (startIdx != 0xffffffff) {

            // Highest particle index in cell
            endIdx = dev_cellEnd[cellID];

            // Iterate over cell particles
            for (i=startIdx; i<endIdx; ++i) {

                // Read particle velocity
                __syncthreads();
                v = dev_vel_sorted[i];
                d = 2.0*dev_x_sorted[i].w;
                n++;
                v_avg += MAKE_FLOAT3(v.x, v.y, v.z);
                d_avg += d;
            }

            v_avg /= n;
            d_avg /= n;
        }

        // save average radius and velocity
        const unsigned int cellidx = idx(x,y,z);
        __syncthreads();
        dev_ns_vp_avg[cellidx] = v_avg;
        dev_ns_d_avg[cellidx]  = d_avg;
    }
}

// Find the drag coefficient as dictated by the Reynold's number
// Shamy and Zeghal (2005).
__device__ Float dragCoefficient(Float re)
{
    Float cd;
    if (re >= 1000.0)
        cd = 0.44;
    else
        cd = 24.0/re*(1.0 + 0.15*pow(re, 0.687));
    return cd;
}

// Determine the fluid-particle interaction drag force based on the Ergun (1952)
// equation for dense packed cells (phi <= 0.8), and the Wen and Yu (1966)
// equation for dilate suspensions (phi > 0.8). Procedure outlined in Shamy and
// Zeghal (2005) and Goniva et al (2010).
// Other interaction forces, such as the pressure gradient in the flow field
// (pressure force), particle rotation (Magnus force), particle acceleration
// (virtual mass force) or a fluid velocity gradient leading to shear (Saffman
// force).
__global__ void findInteractionForce(
        Float*  dev_ns_phi,     // in
        Float   rho,            // in
        Float*  dev_ns_d_avg,   // in
        Float3* dev_ns_vp_avg,  // in
        Float3* dev_ns_v,       // in
        Float3* dev_ns_fi)      // out
{

    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

        const unsigned int cellidx = idx(x,y,z);

        __syncthreads();
        const Float  phi = dev_ns_phi[cellidx];
        const Float3 vf_avg = dev_ns_v[cellidx];

        Float d_avg;
        Float3 vp_avg;
        if (phi < 0.999) {
            __syncthreads();
            d_avg  = dev_ns_d_avg[cellidx];
            vp_avg = dev_ns_vp_avg[cellidx];
        } else {  // cell is empty
            d_avg = 1.0; // some value different from 0
            vp_avg = vf_avg;
        }

        const Float3 v_rel = vf_avg - vp_avg;
        const Float  v_rel_length = length(v_rel);

        const Float not_phi = 1.0 - phi;
        const Float re = (phi*rho*d_avg)/devC_params.nu * v_rel_length;
        const Float cd = dragCoefficient(re);

        Float3 fi = MAKE_FLOAT3(0.0, 0.0, 0.0);
        if (v_rel_length > 0.0) {
            if (phi <= 0.8)       // Ergun equation
                fi = (150.0*devC_params.nu*not_phi*not_phi/(phi*d_avg*d_avg)
                        + 1.75*not_phi*rho*v_rel_length/d_avg)*v_rel;
            else if (phi < 0.999) // Wen and Yu equation
                fi = (3.0/4.0*cd*not_phi*pow(phi, -2.65)*devC_params.nu*rho
                        *v_rel_length/d_avg)*v_rel;
        }

        /*printf("%d,%d,%d\tfi = %f,%f,%f"
                "\tphi = %f\td_avg = %f"
                "\tv_rel = %f,%f,%f\t"
                "\tre = %f\tcd = %f\n",
                x,y,z, fi.x, fi.y, fi.z,
                phi, d_avg,
                v_rel.x, v_rel.y, v_rel.z,
                re, cd);*/

        __syncthreads();
        dev_ns_fi[cellidx] = fi;
    }
}

// Apply the fluid-particle interaction force to all particles in each fluid
// cell.
__global__ void applyParticleInteractionForce(
        Float3* dev_ns_fi,                      // in
        Float*  dev_ns_phi,                     // in
        unsigned int* dev_gridParticleIndex,    // in
        unsigned int* dev_cellStart,            // in
        unsigned int* dev_cellEnd,              // in
        Float4* dev_x_sorted,                   // in
        Float4* dev_force)                      // out
{
    // 3D thread index
    const unsigned int x = blockDim.x * blockIdx.x + threadIdx.x;
    const unsigned int y = blockDim.y * blockIdx.y + threadIdx.y;
    const unsigned int z = blockDim.z * blockIdx.z + threadIdx.z;

    // Check that we are not outside the fluid grid
    if (x < devC_grid.num[0] && y < devC_grid.num[1] && z < devC_grid.num[2]) {

        const unsigned int cellidx = idx(x,y,z);

        __syncthreads();
        const Float3 fi = dev_ns_fi[cellidx];

        // apply to all particle in the cell
        // Calculate linear cell ID
        const unsigned int cellID = x + y * devC_grid.num[0]
            + (devC_grid.num[0] * devC_grid.num[1]) * z; 

        const unsigned int startidx = dev_cellStart[cellID];
        unsigned int endidx, i, origidx;

        Float r, phi;
        Float3 fd;

        if (startidx != 0xffffffff) {

            __syncthreads();
            endidx = dev_cellEnd[cellID];

            for (i=startidx; i<endidx; ++i) {

                __syncthreads();
                origidx = dev_gridParticleIndex[i];
                r = dev_x_sorted[i].w; // radius
                phi = dev_ns_phi[idx(x,y,z)];

                // this term could include the pressure gradient
                //fd = (-grad_p + fi/(1.0 - phi))*(4.0/3.0*M_PI*r*r*r);
                fd = (fi/(1.0 - phi))*(4.0/3.0*M_PI*r*r*r);

                __syncthreads();
                dev_force[origidx] += MAKE_FLOAT4(fd.x, fd.y, fd.z, 0.0);
            }
        }
    }
}
 

// Print final heads and free memory
void DEM::endNSdev()
{
    freeNSmemDev();
}

// vim: tabstop=8 expandtab shiftwidth=4 softtabstop=4
