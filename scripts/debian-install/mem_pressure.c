/*
 * Memory Pressure - Fast memory allocation for swap testing
 * 
 * This program quickly allocates and fills memory with various patterns
 * to trigger swapping. Much faster than Python-based allocation for
 * large memory sizes (7+ GB).
 * 
 * Usage: mem_pressure <size_mb> [pattern_type] [hold_seconds]
 * 
 * pattern_type:
 *   0 = mixed (default) - mix of compressible and non-compressible data
 *   1 = random - low compression ratio
 *   2 = zeros - high compression ratio
 *   3 = sequential - medium compression ratio
 * 
 * hold_seconds: How long to hold memory before exiting (default: 15)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <signal.h>

#define MB_TO_BYTES(mb) ((size_t)(mb) * 1024 * 1024)
#define CHUNK_SIZE (64 * 1024 * 1024)  // 64MB chunks
#define PAGE_SIZE 4096
#define ACCESS_STEP 65536  // 64KB steps for memory access

static volatile int interrupted = 0;

void signal_handler(int signo) {
    fprintf(stderr, "[mem_pressure] Received signal %d, finishing test...\n", signo);
    interrupted = 1;
}

void print_timestamp() {
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char buffer[26];
    strftime(buffer, 26, "%Y-%m-%d %H:%M:%S", tm_info);
    fprintf(stderr, "%s", buffer);
}

// Fast random number generator (LCG)
static unsigned long rand_state = 12345;
static inline unsigned char fast_rand() {
    rand_state = (rand_state * 1103515245 + 12345) & 0x7fffffff;
    return (unsigned char)(rand_state & 0xFF);
}

void fill_pattern(char *buffer, size_t size, int pattern_type, size_t offset) {
    size_t i;
    
    switch (pattern_type) {
        case 1: // Random - low compression
            for (i = 0; i < size; i++) {
                buffer[i] = fast_rand();
            }
            break;
            
        case 2: // Zeros - high compression
            memset(buffer, 0, size);
            break;
            
        case 3: // Sequential - medium compression
            for (i = 0; i < size; i++) {
                buffer[i] = (unsigned char)((offset + i) % 256);
            }
            break;
            
        case 0: // Mixed (default) - realistic workload
        default:
            // Mix of patterns: some compressible, some not
            for (i = 0; i < size; i += PAGE_SIZE) {
                size_t chunk_size = (size - i) < PAGE_SIZE ? (size - i) : PAGE_SIZE;
                int subpattern = ((offset + i) / PAGE_SIZE) % 4;
                
                switch (subpattern) {
                    case 0: // Random bytes (low compression)
                        for (size_t j = 0; j < chunk_size; j++) {
                            buffer[i + j] = fast_rand();
                        }
                        break;
                    case 1: // Repeated pattern (medium compression)
                        memset(buffer + i, (offset + i) % 256, chunk_size);
                        break;
                    case 2: // Zero bytes (high compression)
                        memset(buffer + i, 0, chunk_size);
                        break;
                    case 3: // Mixed (medium compression)
                        for (size_t j = 0; j < chunk_size; j++) {
                            buffer[i + j] = (unsigned char)((offset + i + j) % 256);
                        }
                        break;
                }
            }
            break;
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "Usage: %s <size_mb> [pattern_type] [hold_seconds]\n", argv[0]);
        fprintf(stderr, "Pattern types:\n");
        fprintf(stderr, "  0 = mixed (default) - realistic workload\n");
        fprintf(stderr, "  1 = random - low compression\n");
        fprintf(stderr, "  2 = zeros - high compression\n");
        fprintf(stderr, "  3 = sequential - medium compression\n");
        fprintf(stderr, "Example: %s 2048 0 15\n", argv[0]);
        return 1;
    }

    size_t size_mb = atol(argv[1]);
    int pattern_type = (argc >= 3) ? atoi(argv[2]) : 0;
    int hold_seconds = (argc >= 4) ? atoi(argv[3]) : 15;

    if (size_mb == 0) {
        fprintf(stderr, "[mem_pressure] Error: Invalid size specified\n");
        return 1;
    }

    size_t total_size = MB_TO_BYTES(size_mb);

    // Set up signal handlers
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    fprintf(stderr, "[mem_pressure] "); print_timestamp(); 
    fprintf(stderr, " Starting memory pressure test\n");
    fprintf(stderr, "[mem_pressure] Target: %zu MB (%zu bytes)\n", size_mb, total_size);
    fprintf(stderr, "[mem_pressure] Pattern: %d, Hold time: %d seconds\n", 
            pattern_type, hold_seconds);
    fprintf(stderr, "[mem_pressure] PID: %d\n", getpid());

    // Allocate memory
    fprintf(stderr, "[mem_pressure] Allocating memory...\n");
    char *memory = (char *)malloc(total_size);
    if (memory == NULL) {
        fprintf(stderr, "[mem_pressure] Error: Failed to allocate %zu MB: %s\n", 
                size_mb, strerror(errno));
        
        // Try with half the size
        size_t half_size = total_size / 2;
        fprintf(stderr, "[mem_pressure] Retrying with %zu MB...\n", half_size / (1024 * 1024));
        memory = (char *)malloc(half_size);
        if (memory == NULL) {
            fprintf(stderr, "[mem_pressure] Error: Failed to allocate even half size: %s\n", 
                    strerror(errno));
            return 1;
        }
        total_size = half_size;
        size_mb = half_size / (1024 * 1024);
    }
    fprintf(stderr, "[mem_pressure] Memory allocated: %zu MB\n", size_mb);

    // Fill memory with pattern
    fprintf(stderr, "[mem_pressure] Filling memory with pattern (type %d)...\n", pattern_type);
    size_t filled = 0;
    time_t fill_start = time(NULL);
    
    while (filled < total_size && !interrupted) {
        size_t chunk = (total_size - filled) > CHUNK_SIZE ? CHUNK_SIZE : (total_size - filled);
        fill_pattern(memory + filled, chunk, pattern_type, filled);
        filled += chunk;
        
        // Report progress
        if (filled % CHUNK_SIZE == 0 || filled == total_size) {
            time_t now = time(NULL);
            double elapsed = difftime(now, fill_start);
            double rate = (filled / (1024.0 * 1024.0)) / (elapsed > 0 ? elapsed : 1);
            fprintf(stderr, "[mem_pressure] Filled %zu / %zu MB (%.1f%%) - %.1f MB/s\n", 
                    filled / (1024 * 1024), size_mb, 
                    (float)filled / total_size * 100, rate);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_pressure] Fill interrupted\n");
        free(memory);
        return 1;
    }

    time_t fill_end = time(NULL);
    double fill_time = difftime(fill_end, fill_start);
    fprintf(stderr, "[mem_pressure] Memory fill complete in %.1f seconds\n", fill_time);

    // Access memory multiple times to ensure swapping
    fprintf(stderr, "[mem_pressure] Forcing memory to swap (3 passes)...\n");
    for (int pass = 0; pass < 3 && !interrupted; pass++) {
        fprintf(stderr, "[mem_pressure] Pass %d/3...\n", pass + 1);
        for (size_t i = 0; i < total_size && !interrupted; i += ACCESS_STEP) {
            memory[i] = (memory[i] + 1) % 256;
        }
        usleep(300000); // 0.3 second pause between passes
    }

    if (interrupted) {
        fprintf(stderr, "[mem_pressure] Swap forcing interrupted\n");
        free(memory);
        return 1;
    }

    fprintf(stderr, "[mem_pressure] Memory pressure applied successfully\n");

    // Hold memory for specified duration
    fprintf(stderr, "[mem_pressure] Holding memory for %d seconds...\n", hold_seconds);
    time_t hold_start = time(NULL);
    while (!interrupted && difftime(time(NULL), hold_start) < hold_seconds) {
        sleep(1);
    }

    fprintf(stderr, "[mem_pressure] "); print_timestamp(); 
    fprintf(stderr, " Test complete, releasing memory\n");
    free(memory);

    return 0;
}
