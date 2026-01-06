/*
 * Memory Read Latency Benchmark
 * 
 * Measures page read (page fault + decompress) latency by:
 * 1. Allocating memory
 * 2. Forcing pages to swap out
 * 3. Touching pages to trigger page faults
 * 4. Measuring time per page fault
 * 
 * Usage: mem_read_bench <size_mb> [access_pattern]
 * 
 * access_pattern:
 *   0 = sequential (default) - touch pages in order
 *   1 = random - touch pages randomly
 *   2 = stride - touch every 16th page (cache behavior test)
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
#define REPORT_INTERVAL 1000
#define STRIDE_SIZE 16  // For stride access pattern

static volatile int interrupted = 0;

typedef struct {
    uint64_t *latencies;
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
    
    qsort(stats->latencies, stats->count, sizeof(uint64_t), compare_uint64);
    
    stats->min_ns = stats->latencies[0];
    stats->max_ns = stats->latencies[stats->count - 1];
    
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

void shuffle_array(size_t *array, size_t n) {
    if (n > 1) {
        for (size_t i = 0; i < n - 1; i++) {
            size_t j = i + (fast_rand() % (n - i));
            size_t temp = array[j];
            array[j] = array[i];
            array[i] = temp;
        }
    }
}

void print_results_json(latency_stats_t *stats, int access_pattern, size_t size_mb) {
    if (stats->count == 0) {
        fprintf(stderr, "Error: No latency data collected\n");
        return;
    }
    
    uint64_t avg_ns = stats->total_ns / stats->count;
    uint64_t p50_ns = get_percentile(stats, 50.0);
    uint64_t p95_ns = get_percentile(stats, 95.0);
    uint64_t p99_ns = get_percentile(stats, 99.0);
    
    const char *pattern_name = "sequential";
    if (access_pattern == 1) pattern_name = "random";
    else if (access_pattern == 2) pattern_name = "stride";
    
    printf("{\n");
    printf("  \"test_type\": \"read_latency\",\n");
    printf("  \"size_mb\": %zu,\n", size_mb);
    printf("  \"access_pattern\": \"%s\",\n", pattern_name);
    printf("  \"pages_tested\": %zu,\n", stats->count);
    printf("  \"min_read_us\": %.2f,\n", stats->min_ns / 1000.0);
    printf("  \"max_read_us\": %.2f,\n", stats->max_ns / 1000.0);
    printf("  \"avg_read_us\": %.2f,\n", avg_ns / 1000.0);
    printf("  \"p50_read_us\": %.2f,\n", p50_ns / 1000.0);
    printf("  \"p95_read_us\": %.2f,\n", p95_ns / 1000.0);
    printf("  \"p99_read_us\": %.2f,\n", p99_ns / 1000.0);
    printf("  \"pages_per_sec\": %.0f\n", stats->count / ((double)stats->total_ns / 1000000000.0));
    printf("}\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <size_mb> [access_pattern]\n", argv[0]);
        fprintf(stderr, "Access patterns: 0=sequential (default), 1=random, 2=stride\n");
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
    
    // Parse access pattern
    int access_pattern = 0;
    if (argc >= 3) {
        long pattern_long = strtol(argv[2], &endptr, 10);
        if (*endptr != '\0' || pattern_long < 0 || pattern_long > 2) {
            fprintf(stderr, "Error: Invalid access_pattern (must be 0-2)\n");
            return 1;
        }
        access_pattern = (int)pattern_long;
    }
    
    size_t total_size = MB_TO_BYTES(size_mb);
    size_t num_pages = total_size / PAGE_SIZE;
    
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    
    const char *pattern_name = "sequential";
    if (access_pattern == 1) pattern_name = "random";
    else if (access_pattern == 2) pattern_name = "stride";
    
    fprintf(stderr, "[mem_read_bench] Starting read latency test\n");
    fprintf(stderr, "[mem_read_bench] Size: %zu MB, Pages: %zu, Pattern: %s\n", 
            size_mb, num_pages, pattern_name);
    
    // Allocate memory with mmap
    char *memory = mmap(NULL, total_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to mmap %zu MB: %s\n", size_mb, strerror(errno));
        return 1;
    }
    
    // Set access pattern hint
    if (access_pattern == 0) {
        madvise(memory, total_size, MADV_SEQUENTIAL);
    } else {
        madvise(memory, total_size, MADV_RANDOM);
    }
    
    // Allocate latency stats
    latency_stats_t stats;
    stats.latencies = malloc(num_pages * sizeof(uint64_t));
    if (stats.latencies == NULL) {
        fprintf(stderr, "Error: Failed to allocate stats array\n");
        munmap(memory, total_size);
        return 1;
    }
    stats.count = 0;
    
    // Fill memory with pattern
    fprintf(stderr, "[mem_read_bench] Filling memory...\n");
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        char *page = memory + (i * PAGE_SIZE);
        // Write a recognizable pattern
        for (size_t j = 0; j < PAGE_SIZE; j++) {
            page[j] = (unsigned char)((i + j) % 256);
        }
        
        if ((i + 1) % (num_pages / 10) == 0 || i == num_pages - 1) {
            fprintf(stderr, "[mem_read_bench] Fill progress: %zu/%zu pages\n", i + 1, num_pages);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_read_bench] Interrupted during fill\n");
        free(stats.latencies);
        munmap(memory, total_size);
        return 1;
    }
    
    // Force all pages to swap out
    fprintf(stderr, "[mem_read_bench] Forcing pages to swap out...\n");
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        madvise(memory + (i * PAGE_SIZE), PAGE_SIZE, MADV_PAGEOUT);
        
        if ((i + 1) % (num_pages / 10) == 0 || i == num_pages - 1) {
            fprintf(stderr, "[mem_read_bench] Pageout progress: %zu/%zu pages\n", i + 1, num_pages);
        }
    }
    
    // Give kernel time to actually swap out
    fprintf(stderr, "[mem_read_bench] Waiting for swap-out to complete...\n");
    sleep(2);
    
    if (interrupted) {
        fprintf(stderr, "[mem_read_bench] Interrupted during pageout\n");
        free(stats.latencies);
        munmap(memory, total_size);
        return 1;
    }
    
    // Create access order based on pattern
    size_t *access_order = malloc(num_pages * sizeof(size_t));
    if (access_order == NULL) {
        fprintf(stderr, "Error: Failed to allocate access order array\n");
        free(stats.latencies);
        munmap(memory, total_size);
        return 1;
    }
    
    if (access_pattern == 2) {
        // Stride pattern - every Nth page
        size_t stride_count = 0;
        for (size_t i = 0; i < num_pages; i += STRIDE_SIZE) {
            access_order[stride_count++] = i;
        }
        num_pages = stride_count;  // Update to actual number we'll test
    } else {
        // Sequential or random
        for (size_t i = 0; i < num_pages; i++) {
            access_order[i] = i;
        }
        if (access_pattern == 1) {
            shuffle_array(access_order, num_pages);
        }
    }
    
    // Measure read latency by touching pages
    fprintf(stderr, "[mem_read_bench] Measuring read latency (triggering page faults)...\n");
    
    struct timespec start, end;
    volatile char dummy = 0;  // Prevent optimization
    
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        size_t page_idx = access_order[i];
        char *page = memory + (page_idx * PAGE_SIZE);
        
        clock_gettime(CLOCK_MONOTONIC, &start);
        
        // Read from page to trigger page fault
        dummy += page[0];
        
        clock_gettime(CLOCK_MONOTONIC, &end);
        
        stats.latencies[stats.count++] = timespec_diff_ns(&start, &end);
        
        if ((i + 1) % REPORT_INTERVAL == 0) {
            fprintf(stderr, "[mem_read_bench] Tested: %zu/%zu pages\n", i + 1, num_pages);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_read_bench] Interrupted during measurement\n");
    }
    
    fprintf(stderr, "[mem_read_bench] Test complete, calculating statistics...\n");
    
    // Calculate and print statistics
    calculate_statistics(&stats);
    print_results_json(&stats, access_pattern, size_mb);
    
    // Cleanup
    free(access_order);
    free(stats.latencies);
    munmap(memory, total_size);
    
    return interrupted ? 1 : 0;
}
