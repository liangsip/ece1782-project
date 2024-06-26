#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <chrono>
#include <cuda_runtime.h>
#include <string.h>
#include "utils-cuda.h"

/*
    Base version of CUDA implementation, no special optimization
*/

#define AES_KEY_SIZE 16
#define AES_BLOCK_SIZE 16

__device__ unsigned char mul(unsigned char a, unsigned char b) {
    unsigned char p = 0;
    unsigned char high_bit_mask = 0x80;
    unsigned char high_bit = 0;
    unsigned char modulo = 0x1B; /* x^8 + x^4 + x^3 + x + 1 */

    for (int i = 0; i < 8; i++) {
        if (b & 1) {
            p ^= a;
        }

        high_bit = a & high_bit_mask;
        a <<= 1;
        if (high_bit) {
            a ^= modulo;
        }
        b >>= 1;
    }

    return p;
}

/*expand the 16 byte key into 44 word expanded key*/
void KeyExpansionHost(unsigned char* key, unsigned char* expandedKey) {
    int i = 0;
    //Copy the key into expanded key first 4 word
    while (i < 4) {
        for (int j = 0; j < 4; j++) {
            expandedKey[i * 4 + j] = key[i * 4 + j];
        }
        i++;
    }

    int rconIteration = 1;
    unsigned char temp[4];

    //generate next 40 word of expanded key
    while (i < 44) {
        //get store previous word into temp
        for (int j = 0; j < 4; j++) {
            temp[j] = expandedKey[(i - 1) * 4 + j];
        }

        //if i is multiple of 4 apply g(w[i-1])
        if (i % 4 == 0) {
            unsigned char k = temp[0];
            for (int j = 0; j < 3; j++) {
                temp[j] = temp[j + 1];
            }
            temp[3] = k;

            for (int j = 0; j < 4; j++) {
                // Use the host-accessible arrays
                temp[j] = h_sbox[temp[j]] ^ (j == 0 ? h_rcon[rconIteration++] : 0);
            }
        }

        //temp (W[i-1]) XOR with W[i-4]
        for (int j = 0; j < 4; j++) {
            expandedKey[i * 4 + j] = expandedKey[(i - 4) * 4 + j] ^ temp[j];
        }
        i++;
    }
}

__device__ void SubBytes(unsigned char *state, unsigned char *d_sbox) {
    for (int i = 0; i < 16; ++i) {
        state[i] = d_sbox[state[i]];
    }
}

__device__ void ShiftRows(unsigned char *state) {
    unsigned char tmp[16];

    /* Column 1 */
    tmp[0] = state[0];
    tmp[1] = state[5];
    tmp[2] = state[10];
    tmp[3] = state[15];
    /* Column 2 */
    tmp[4] = state[4];
    tmp[5] = state[9];
    tmp[6] = state[14];
    tmp[7] = state[3];
    /* Column 3 */
    tmp[8] = state[8];
    tmp[9] = state[13];
    tmp[10] = state[2];
    tmp[11] = state[7];
    /* Column 4 */
    tmp[12] = state[12];
    tmp[13] = state[1];
    tmp[14] = state[6];
    tmp[15] = state[11];

    memcpy(state, tmp, 16);
}

__device__ void MixColumns(unsigned char *state) {
    unsigned char tmp[16];

    for (int i = 0; i < 4; ++i) {
        tmp[i*4] = (unsigned char)(mul(0x02, state[i*4]) ^ mul(0x03, state[i*4+1]) ^ state[i*4+2] ^ state[i*4+3]);
        tmp[i*4+1] = (unsigned char)(state[i*4] ^ mul(0x02, state[i*4+1]) ^ mul(0x03, state[i*4+2]) ^ state[i*4+3]);
        tmp[i*4+2] = (unsigned char)(state[i*4] ^ state[i*4+1] ^ mul(0x02, state[i*4+2]) ^ mul(0x03, state[i*4+3]));
        tmp[i*4+3] = (unsigned char)(mul(0x03, state[i*4]) ^ state[i*4+1] ^ state[i*4+2] ^ mul(0x02, state[i*4+3]));
    }

    memcpy(state, tmp, 16);
}

__device__ void AddRoundKey(unsigned char *state, const unsigned char *roundKey) {
    for (int i = 0; i < 16; ++i) {
        state[i] ^= roundKey[i];
    }
}

__device__ void aes_encrypt_block(unsigned char *input, unsigned char *output, unsigned char *expandedKey, unsigned char *d_sbox) {
    unsigned char state[16];

    // Copy the input to the state array
    for (int i = 0; i < 16; ++i) {
        state[i] = input[i];
    }

    // Add the round key to the state
    //Before the round-based processing, the input is XOR with first 4 word of expanded key
    AddRoundKey(state, expandedKey);

    // Perform 9 rounds of substitutions, shifts, mixes, and round key additions
    for (int round = 1; round < 10; ++round) {
        SubBytes(state, d_sbox);
        ShiftRows(state);
        MixColumns(state);
        AddRoundKey(state, expandedKey + round * 16);
    }

    // Perform the final round (without MixColumns)
    SubBytes(state, d_sbox);
    ShiftRows(state);
    AddRoundKey(state, expandedKey + 10 * 16);

    // Copy the state to the output
    for (int i = 0; i < 16; ++i) {
        output[i] = state[i];
    }
}

__device__ void increment_counter(unsigned char *counter, int increment) {
    int carry = increment;
    for (int i = AES_BLOCK_SIZE - 1; i >= 0; i--) {
        int sum = counter[i] + carry;
        counter[i] = sum & 0xFF;
        carry = sum >> 8;
        if (carry == 0) {
            break;
        }
    }
}

__global__ void aes_ctr_encrypt_kernel(unsigned char *plaintext, unsigned char *ciphertext, unsigned char *expandedKey, unsigned char *iv, unsigned char *d_sbox, int numBlocks, int dataSize) {
    // Calculate the global block ID
    int tid = blockIdx.x * blockDim.x + threadIdx.x;

    // Check if the block is within the number of blocks
    if (tid < numBlocks) {
        // Create a counter array
        unsigned char counter[AES_BLOCK_SIZE];

        // Copy the IV to the counter
        memcpy(counter, iv, AES_BLOCK_SIZE);

        // Increment the counter by the block ID
        increment_counter(counter, tid);

        // Calculate the block size
        int blockSize = (tid == numBlocks - 1 && dataSize % AES_BLOCK_SIZE != 0) ? dataSize % AES_BLOCK_SIZE : AES_BLOCK_SIZE;

        // Encrypt the counter to get the ciphertext block
        unsigned char ciphertextBlock[AES_BLOCK_SIZE];
        aes_encrypt_block(counter, ciphertextBlock, expandedKey, d_sbox);

        // XOR the plaintext with the ciphertext block
        for (int i = 0; i < blockSize; ++i) {
            ciphertext[tid * AES_BLOCK_SIZE + i] = plaintext[tid * AES_BLOCK_SIZE + i] ^ ciphertextBlock[i];
        }
    }
}

int main(int argc, char* argv[]) {
    // Check if filename is provided
    if (argc < 2) {
        printf("Usage: %s <filename>\n", argv[0]);
        return 1;
    }

    // Get the file extension
    std::string extension = getFileExtension(argv[1]);

    // Get the start time
    auto start = std::chrono::high_resolution_clock::now();

    // Read the key and IV
    unsigned char key[16];
    unsigned char iv[16];
    read_key_or_iv(key, sizeof(key), "key.txt");
    read_key_or_iv(iv, sizeof(iv), "iv.txt");

    // Determine the size of the file and read the plaintext
    size_t dataSize;
    unsigned char *plaintext;
    read_file_as_binary(&plaintext, &dataSize, argv[1]); 

    unsigned char *d_plaintext, *d_ciphertext, *d_iv;
    unsigned char *d_expandedKey;
    unsigned char *d_sbox;

    // Call the host function to expand the key
    unsigned char expandedKey[176];
    KeyExpansionHost(key, expandedKey);

    // Calculate the number of AES blocks needed
    size_t numBlocks = (dataSize + AES_BLOCK_SIZE - 1) / AES_BLOCK_SIZE;

    // Define the size of the grid and the blocks
    dim3 threadsPerBlock(256); // Use a reasonable number of threads per block
    dim3 blocksPerGrid((numBlocks + threadsPerBlock.x - 1) / threadsPerBlock.x);

    // Allocate device memory
    cudaMalloc((void **)&d_iv, AES_BLOCK_SIZE * sizeof(unsigned char));
    cudaMalloc((void **)&d_expandedKey, 176); 
    cudaMalloc((void **)&d_plaintext, dataSize * sizeof(unsigned char));
    cudaMalloc((void **)&d_ciphertext, dataSize * sizeof(unsigned char));
    cudaMalloc((void **)&d_sbox, 256 * sizeof(unsigned char));

    // Copy host memory to device
    cudaMemcpy(d_plaintext, plaintext, dataSize * sizeof(unsigned char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_iv, iv, AES_BLOCK_SIZE * sizeof(unsigned char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_expandedKey, expandedKey, 176, cudaMemcpyHostToDevice); 
    cudaMemcpy(d_sbox, h_sbox, sizeof(h_sbox), cudaMemcpyHostToDevice);

    // Launch AES-CTR encryption kernel
    aes_ctr_encrypt_kernel<<<blocksPerGrid, threadsPerBlock>>>(d_plaintext, d_ciphertext, d_expandedKey, d_iv, d_sbox, numBlocks, dataSize);

    // Synchronize device
    cudaDeviceSynchronize();

    // Copy device ciphertext back to host
    unsigned char *ciphertext = new unsigned char[dataSize];
    cudaMemcpy(ciphertext, d_ciphertext, dataSize * sizeof(unsigned char), cudaMemcpyDeviceToHost);

    // Output encoded text to a file
    write_encrypted(ciphertext, dataSize, "encrypted.bin");

    // Cleanup
    cudaFree(d_plaintext);
    cudaFree(d_ciphertext);
    cudaFree(d_iv);
    cudaFree(d_expandedKey);
    cudaFree(d_sbox);
    delete[] ciphertext;
    delete[] plaintext; 

    // Get the stop time
    auto stop = std::chrono::high_resolution_clock::now();

    // Calculate the elapsed time and print
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(stop - start);
    std::cout << "time: " << duration.count() << " ms\n";

    // After encrypting, append the file extension to the encrypted data
    // appendFileExtension("encrypted.bin", extension);
    
    return 0;
}