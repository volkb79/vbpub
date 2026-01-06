/*
 * Memory Locker - Lock RAM to prevent swapping during tests
 * 
 * This program allocates and pins a specified amount of memory using mlock()
 * to prevent it from being swapped out. This ensures that only the test memory
 * will be subject to swapping during ZRAM/ZSWAP benchmarks.
 * 
 * Usage: mem_locker <size_mb>
 * 
 * The program stays resident until killed, keeping the memory locked.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <signal.h>
#include <time.h>

#define MB_TO_BYTES(mb) ((size_t)(mb) * 1024 * 1024)
#define CHUNK_SIZE (64 * 1024 * 1024)  // 64MB chunks for progress reporting

static volatile int keep_running = 1;
static void *locked_memory = NULL;
static size_t total_size = 0;

void signal_handler(int signo) {
    fprintf(stderr, "[mem_locker] Received signal %d, cleaning up...\n", signo);
    keep_running = 0;
}

void cleanup() {
    if (locked_memory != NULL && total_size > 0) {
        fprintf(stderr, "[mem_locker] Unlocking %zu MB of memory...\n", total_size / (1024 * 1024));
        munlock(locked_memory, total_size);
        free(locked_memory);
        locked_memory = NULL;
    }
}

void print_timestamp() {
    time_t now = time(NULL);
    struct tm *tm_info = localtime(&now);
    char buffer[26];
    strftime(buffer, 26, "%Y-%m-%d %H:%M:%S", tm_info);
    fprintf(stderr, "%s", buffer);
}

int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <size_mb>\n", argv[0]);
        fprintf(stderr, "Example: %s 1024  (locks 1GB of RAM)\n", argv[0]);
        return 1;
    }

    size_t size_mb = atol(argv[1]);
    if (size_mb == 0) {
        fprintf(stderr, "[mem_locker] Error: Invalid size specified\n");
        return 1;
    }

    total_size = MB_TO_BYTES(size_mb);

    fprintf(stderr, "[mem_locker] "); print_timestamp(); 
    fprintf(stderr, " Starting memory locker\n");
    fprintf(stderr, "[mem_locker] Target: Lock %zu MB (%zu bytes) of RAM\n", 
            size_mb, total_size);
    fprintf(stderr, "[mem_locker] PID: %d\n", getpid());

    // Set up signal handlers for graceful shutdown
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    atexit(cleanup);

    // Allocate memory
    fprintf(stderr, "[mem_locker] Allocating memory...\n");
    locked_memory = malloc(total_size);
    if (locked_memory == NULL) {
        fprintf(stderr, "[mem_locker] Error: Failed to allocate %zu MB: %s\n", 
                size_mb, strerror(errno));
        return 1;
    }
    fprintf(stderr, "[mem_locker] Memory allocated successfully\n");

    // Fill memory to ensure it's actually allocated (not just virtual)
    fprintf(stderr, "[mem_locker] Filling memory to force allocation...\n");
    size_t filled = 0;
    char *ptr = (char *)locked_memory;
    
    while (filled < total_size) {
        size_t chunk = (total_size - filled) > CHUNK_SIZE ? CHUNK_SIZE : (total_size - filled);
        memset(ptr + filled, 0xAA, chunk);
        filled += chunk;
        
        // Report progress every 64MB
        if (filled % CHUNK_SIZE == 0 || filled == total_size) {
            fprintf(stderr, "[mem_locker] Filled %zu / %zu MB (%.1f%%)\n", 
                    filled / (1024 * 1024), size_mb, 
                    (float)filled / total_size * 100);
        }
    }
    fprintf(stderr, "[mem_locker] Memory fill complete\n");

    // Lock memory to prevent swapping
    fprintf(stderr, "[mem_locker] Locking memory with mlock()...\n");
    if (mlock(locked_memory, total_size) != 0) {
        fprintf(stderr, "[mem_locker] Warning: mlock() failed: %s\n", strerror(errno));
        fprintf(stderr, "[mem_locker] This may happen if:\n");
        fprintf(stderr, "[mem_locker]   - RLIMIT_MEMLOCK is too low\n");
        fprintf(stderr, "[mem_locker]   - Not running as root\n");
        fprintf(stderr, "[mem_locker]   - Insufficient memory\n");
        fprintf(stderr, "[mem_locker] Continuing without mlock, memory may still be swapped...\n");
    } else {
        fprintf(stderr, "[mem_locker] Memory locked successfully\n");
    }

    fprintf(stderr, "[mem_locker] "); print_timestamp(); 
    fprintf(stderr, " Memory locker active (kill with SIGTERM or SIGINT)\n");
    fprintf(stderr, "[mem_locker] Holding %zu MB locked until terminated...\n", size_mb);

    // Stay resident, keeping memory locked
    while (keep_running) {
        sleep(1);
    }

    fprintf(stderr, "[mem_locker] "); print_timestamp(); 
    fprintf(stderr, " Shutting down\n");
    cleanup();

    return 0;
}
