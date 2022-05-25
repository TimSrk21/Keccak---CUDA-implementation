#include <stdlib.h>
#include <stdio.h>

#include <iostream>
#include <fstream>
#include <sstream> 
#include <chrono>
#include <thread> 

#define LOGG true
#define BUFFER_SIZE 400

typedef unsigned char uint8_t;

typedef char* string_t;

#define total 1600
#define rate 1088

#define rounds 24

#define totalBytes total/8
#define rateBytes rate/8
#define rateBytesBuffer rateBytes*BUFFER_SIZE
#define rateLanes rate/64

#define delim_begin 0x06
#define delim_end 0x80

#define ROT(a, offset) ((((uint64_t)a) << offset) ^ (((uint64_t)a) >> (64-offset))) //credit
#define state (*State)
#define lane ((uint64_t*)state._8)

__device__ __constant__ uint8_t rho[25] =
    {0, 1, 62, 28, 27,
     36, 44, 6, 55, 20,
     3, 10, 43, 25, 39,
     41, 45, 15, 21, 8,
     18, 2, 61, 56, 14};

__device__ __constant__ uint8_t pi[25] =
    {0, 6, 12, 18, 24,
     3, 9, 10, 16, 22,
     1, 7, 13, 19, 20,
     4, 5, 11, 17, 23,
     2, 8, 14, 15, 21};

__device__ __constant__ uint64_t iota[24] =
  {
    0x0000000000000001UL, 0x0000000000008082UL,0x800000000000808aUL, 0x8000000080008000UL,
    0x000000000000808bUL, 0x0000000080000001UL,0x8000000080008081UL, 0x8000000000008009UL,
    0x000000000000008aUL, 0x0000000000000088UL,0x0000000080008009UL, 0x000000008000000aUL,
    0x000000008000808bUL, 0x800000000000008bUL,0x8000000000008089UL, 0x8000000000008003UL,
    0x8000000000008002UL, 0x8000000000000080UL,0x000000000000800aUL, 0x800000008000000aUL,
    0x8000000080008081UL, 0x8000000000008080UL,0x0000000080000001UL, 0x8000000080008008UL
};

union INTER{
    uint64_t _64[25];
    uint8_t _8[200];
};

__global__ void Keccak(string_t input, int size, union INTER* State){
    union INTER iState; 
    int buffer_i = 0;
    while(size>0 && (buffer_i++) < BUFFER_SIZE){
        if(size<rateBytes){    
            for(int i=0; i<size; i++)
                state._8[i] ^= input[i];
            state._8[size] ^= delim_begin;//padding
            state._8[rateBytes - 1] ^= delim_end;
        }
        else{
            for(int i=0; i<rateLanes; i++){
                state._64[i] ^= ((uint64_t*)input)[i];
            }   
            input += rateBytes;
        }
        
        __shared__ uint64_t CrossPlane[5];
        uint64_t D;

        uint8_t i = threadIdx.x;
        uint8_t i_5 = i*blockDim.x;

        for(int round = 0; round<rounds; round++){
            //Omega
        CrossPlane[i] = state._64[i] ^ state._64[i + 5] ^ state._64[i + 10] ^ state._64[i + 15] ^ state._64[i + 20];
        //__syncthreads();

        D = CrossPlane[i==0?4:(i-1)] ^ ROT(CrossPlane[i==4?0:(i+1)], 1);
        for(int y = 0; y<5; y++)
            {state._64[i + y*5] ^= D;}
        //__syncthreads();

        int indx = 0;
        //Rho and Pi
        for(int x = 0; x<5; x++){
            indx = pi[i_5+x];
            iState._64[i_5+x] = ROT(state._64[indx], rho[indx]);
        }
        //__syncthreads();

        //Chi
        for(int x = 0; x<5; x++)
        {
            state._64[x+i_5] = iState._64[x+i_5] ^ (~iState._64[(x+1)%5 +i_5] & iState._64[(x+2)%5 +i_5]);
        }
        //__syncthreads();

        state._64[0] ^= iota[round];
        __syncthreads();
        }
        size -= rateBytes;
    }
}

std::ofstream myfile;

void hostr(const char* path, int times=1){
    for(int tm = 0; tm<times; tm++){
        std::streamsize size;// = message2.length();
        std::streamsize sizeInit;
        char* contents = new char[rateBytesBuffer];
        std::ifstream istr(path, std::ios::in | std::ios::binary);
        std::streambuf* pbuf = NULL;

        if (istr) 
        {
            pbuf = istr.rdbuf();
            size = pbuf->pubseekoff(0, istr.end);
            sizeInit = size;
            std::cout << " File size is: " << size << "\n";
            pbuf->pubseekoff(0, istr.beg);       // rewind 
        }
        unsigned char output[32] = { "" };

        cudaEvent_t start, stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);

        cudaEventRecord(start);

        char* input_d1;
        cudaMalloc((void**)&input_d1, rateBytesBuffer);

        char* input_d2;
        cudaMalloc((void**)&input_d2, rateBytesBuffer);

        union INTER* State_d;
        cudaMalloc((void**)&State_d, sizeof(union INTER));
        cudaMemset(State_d, 0, 200);

        cudaStream_t stream_c;
        cudaStream_t stream_k;
        cudaStreamCreate(&stream_c);
        cudaStreamCreate(&stream_k);
        
        int itter = 0;
        double hashed = pbuf->sgetn(contents, rateBytesBuffer);
        cudaMemcpyAsync((itter?input_d2:input_d1), contents, size>rateBytesBuffer?rateBytesBuffer:size, cudaMemcpyHostToDevice, stream_c);
        size -= rateBytesBuffer;

        for(int offset = 0; size>0; itter = !itter){
            Keccak<<<1,5,0,stream_k>>>((itter?input_d2:input_d1), size+rateBytesBuffer, State_d);
            double hashed = pbuf->sgetn(contents, rateBytesBuffer);
            size -= rateBytesBuffer;
            cudaMemcpyAsync((itter?input_d1:input_d2), contents, rateBytesBuffer, cudaMemcpyHostToDevice, stream_c);  
            cudaStreamSynchronize(stream_k);
        }
        Keccak<<<1,5,0,stream_c>>>((itter?input_d2:input_d1), size+rateBytesBuffer, State_d); 
        cudaMemcpyAsync(output, State_d, 32 * sizeof(char), cudaMemcpyDeviceToHost, stream_c); 
        cudaStreamSynchronize(stream_c);

        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
        float milliseconds = 0;
        cudaEventElapsedTime(&milliseconds, start, stop);
        
        printf(" %s - ", path);
        std::cout << "elapsed time: " << milliseconds/1000 << "s\n";
        if(LOGG)myfile << path << "; " << milliseconds/1000 << "\n" ;

        for (int i = 0; i < 32; i++)
            printf("%02x", output[i]);

        cudaFree(input_d1);
        cudaFree(input_d2);
        cudaFree(State_d);
        printf("\n\n");
        istr.close();
        //if(LOGG)myfile << path << "; " << elapsed_seconds.count() << "\n" ;
    }
}

int main( int argc, char *argv[] ){
    if(LOGG)myfile.open ("b_2s5t.csv");
    for(int pt = 1; pt<argc; pt++)
        hostr(argv[pt],1);
    if(LOGG)myfile << "\n" ;
    if(LOGG)myfile.close();
}