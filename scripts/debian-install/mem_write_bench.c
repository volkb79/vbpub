/*
 * Memory Write Latency Benchmark
 * 
 * Measures page write (swap-out) latency by forcing pages to be swapped
 * using madvise(MADV_PAGEOUT). Provides per-page timing and statistics.
 * 
 * Usage: mem_write_bench <size_mb> [pattern_type]
 * 
 * pattern_type:
 *   0 = mixed (default) - realistic workload
 *   1 = random - low compression
 *   2 = zeros - high compression
 *   3 = sequential - medium compression
 * 
 * Output: JSON format with latency statistics
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <sys/mman.h>
#include <stdint.h>

#define MB_TO_BYTES(mb) ((size_t)(mb) * 1024 * 1024)
#define PAGE_SIZE 4096
#define REPORT_INTERVAL 1000  // Report progress every N pages

static volatile int interrupted = 0;

// Latency statistics
typedef struct {
    uint64_t *latencies;  // Array of per-page latencies in nanoseconds
    size_t count;
    uint64_t min_ns;
    uint64_t max_ns;
    uint64_t total_ns;
} latency_stats_t;

void signal_handler(int signo) {
    interrupted = 1;
}

// Fast random number generator (LCG)
static unsigned long rand_state = 12345;
static inline unsigned char fast_rand() {
    rand_state = (rand_state * 1103515245 + 12345) & 0x7fffffff;
    return (unsigned char)(rand_state & 0xFF);
}

void fill_page(char *page, int pattern_type, size_t page_index) {
    switch (pattern_type) {
        case 1: // Random
            for (size_t i = 0; i < PAGE_SIZE; i++) {
                page[i] = fast_rand();
            }
            break;
            
        case 2: // Zeros
            memset(page, 0, PAGE_SIZE);
            break;
            
        case 3: // Sequential
            for (size_t i = 0; i < PAGE_SIZE; i++) {
                page[i] = (unsigned char)((page_index * PAGE_SIZE + i) % 256);
            }
            break;
            
        case 0: // Mixed
        default:
            {
                int subpattern = page_index % 4;
                switch (subpattern) {
                    case 0: // Random
                        for (size_t i = 0; i < PAGE_SIZE; i++) {
                            page[i] = fast_rand();
                        }
                        break;
                    case 1: // Repeated
                        memset(page, page_index % 256, PAGE_SIZE);
                        break;
                    case 2: // Zeros
                        memset(page, 0, PAGE_SIZE);
                        break;
                    case 3: // Sequential
                        for (size_t i = 0; i < PAGE_SIZE; i++) {
                            page[i] = (unsigned char)((page_index * PAGE_SIZE + i) % 256);
                        }
                        break;
                }
            }
            break;
    }
}

uint64_t timespec_diff_ns(struct timespec *start, struct timespec *end) {
    uint64_t start_ns = (uint64_t)start->tv_sec * 1000000000ULL + start->tv_nsec;
    uint64_t end_ns = (uint64_t)end->tv_sec * 1000000000ULL + end->tv_nsec;
    return end_ns - start_ns;
}

int compare_uint64(const void *a, const void *b) {
    uint64_t val_a = *(const uint64_t *)a;
    uint64_t val_b = *(const uint64_t *)b;
    if (val_a < val_b) return -1;
    if (val_a > val_b) return 1;
    return 0;
}

void calculate_statistics(latency_stats_t *stats) {
    if (stats->count == 0) return;
    
    // Sort latencies for percentile calculation
    qsort(stats->latencies, stats->count, sizeof(uint64_t), compare_uint64);
    
    // Find min and max
    stats->min_ns = stats->latencies[0];
    stats->max_ns = stats->latencies[stats->count - 1];
    
    // Calculate total
    stats->total_ns = 0;
    for (size_t i = 0; i < stats->count; i++) {
        stats->total_ns += stats->latencies[i];
    }
}

uint64_t get_percentile(latency_stats_t *stats, double percentile) {
    if (stats->count == 0) return 0;
    
    size_t index = (size_t)((percentile / 100.0) * stats->count);
    if (index >= stats->count) index = stats->count - 1;
    
    return stats->latencies[index];
}

void print_results_json(latency_stats_t *stats, int pattern_type, size_t size_mb) {
    if (stats->count == 0) {
        fprintf(stderr, "Error: No latency data collected\n");
        return;
    }
    
    uint64_t avg_ns = stats->total_ns / stats->count;
    uint64_t p50_ns = get_percentile(stats, 50.0);
    uint64_t p95_ns = get_percentile(stats, 95.0);
    uint64_t p99_ns = get_percentile(stats, 99.0);
    
    // Convert to microseconds for output
    printf("{\n");
    printf("  \"test_type\": \"write_latency\",\n");
    printf("  \"size_mb\": %zu,\n", size_mb);
    printf("  \"pattern\": %d,\n", pattern_type);
    printf("  \"pages_tested\": %zu,\n", stats->count);
    printf("  \"min_write_us\": %.2f,\n", stats->min_ns / 1000.0);
    printf("  \"max_write_us\": %.2f,\n", stats->max_ns / 1000.0);
    printf("  \"avg_write_us\": %.2f,\n", avg_ns / 1000.0);
    printf("  \"p50_write_us\": %.2f,\n", p50_ns / 1000.0);
    printf("  \"p95_write_us\": %.2f,\n", p95_ns / 1000.0);
    printf("  \"p99_write_us\": %.2f,\n", p99_ns / 1000.0);
    printf("  \"pages_per_sec\": %.0f,\n", stats->count / ((double)stats->total_ns / 1000000000.0));
    printf("  \"mb_per_sec\": %.2f\n", (stats->count * PAGE_SIZE / (1024.0 * 1024.0)) / ((double)stats->total_ns / 1000000000.0));
    printf("}\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <size_mb> [pattern_type]\n", argv[0]);
        fprintf(stderr, "Pattern types: 0=mixed (default), 1=random, 2=zeros, 3=sequential\n");
        return 1;
    }
    
    // Parse size
    char *endptr;
    unsigned long long size_mb_ull = strtoull(argv[1], &endptr, 10);
    if (*endptr != '\0' || size_mb_ull == 0 || size_mb_ull > (SIZE_MAX / (1024 * 1024))) {
        fprintf(stderr, "Error: Invalid size specified\n");
        return 1;
    }
    size_t size_mb = (size_t)size_mb_ull;
    
    // Parse pattern
    int pattern_type = 0;
    if (argc >= 3) {
        long pattern_long = strtol(argv[2], &endptr, 10);
        if (*endptr != '\0' || pattern_long < 0 || pattern_long > 3) {
            fprintf(stderr, "Error: Invalid pattern_type (must be 0-3)\n");
            return 1;
        }
        pattern_type = (int)pattern_long;
    }
    
    size_t total_size = MB_TO_BYTES(size_mb);
    size_t num_pages = total_size / PAGE_SIZE;
    
    // Setup signal handlers
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    
    fprintf(stderr, "[mem_write_bench] Starting write latency test\n");
    fprintf(stderr, "[mem_write_bench] Size: %zu MB, Pages: %zu, Pattern: %d\n", 
            size_mb, num_pages, pattern_type);
    
    // Allocate memory with mmap for page alignment
    char *memory = mmap(NULL, total_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to mmap %zu MB: %s\n", size_mb, strerror(errno));
        return 1;
    }
    
    // Allocate latency stats - check for overflow
    if (num_pages > SIZE_MAX / sizeof(uint64_t)) {
        fprintf(stderr, "Error: Test size too large, would overflow\n");
        munmap(memory, total_size);
        return 1;
    }
    
    latency_stats_t stats;
    stats.latencies = malloc(num_pages * sizeof(uint64_t));
    if (stats.latencies == NULL) {
        fprintf(stderr, "Error: Failed to allocate stats array\n");
        munmap(memory, total_size);
        return 1;
    }
    stats.count = 0;
    stats.min_ns = UINT64_MAX;
    stats.max_ns = 0;
    stats.total_ns = 0;
    
    // Fill memory with pattern
    fprintf(stderr, "[mem_write_bench] Filling memory...\n");
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        fill_page(memory + (i * PAGE_SIZE), pattern_type, i);
        
        // Report progress - avoid division by zero
        if (num_pages >= 10 && ((i + 1) % (num_pages / 10) == 0 || i == num_pages - 1)) {
            fprintf(stderr, "[mem_write_bench] Progress: %zu/%zu pages (%.0f%%)\n",
                    i + 1, num_pages, ((i + 1) * 100.0) / num_pages);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_write_bench] Interrupted during fill\n");
        free(stats.latencies);
        munmap(memory, total_size);
        return 1;
    }
    
    // Measure write latency by forcing page-out
    fprintf(stderr, "[mem_write_bench] Measuring write latency (forcing page-out)...\n");
    
    struct timespec start, end;
    
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        char *page = memory + (i * PAGE_SIZE);
        
        // Force this page to be swapped out
        clock_gettime(CLOCK_MONOTONIC, &start);
        
        int result = madvise(page, PAGE_SIZE, MADV_PAGEOUT);
        
        clock_gettime(CLOCK_MONOTONIC, &end);
        
        if (result == 0) {
            stats.latencies[stats.count++] = timespec_diff_ns(&start, &end);
        }
        
        // Report progress
        if ((i + 1) % REPORT_INTERVAL == 0) {
            fprintf(stderr, "[mem_write_bench] Tested: %zu/%zu pages\n", i + 1, num_pages);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_write_bench] Interrupted during measurement\n");
    }
    
    fprintf(stderr, "[mem_write_bench] Test complete, calculating statistics...\n");
    
    // Calculate and print statistics
    calculate_statistics(&stats);
    print_results_json(&stats, pattern_type, size_mb);
    
    // Cleanup
    free(stats.latencies);
    munmap(memory, total_size);
    
    return interrupted ? 1 : 0;
}
