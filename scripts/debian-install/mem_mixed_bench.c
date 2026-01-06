/*
 * Memory Mixed Workload Benchmark
 * 
 * Measures latency for realistic mixed read/write workloads:
 * - Random access pattern
 * - Mix of reads and writes
 * - Various data compressibility levels
 * 
 * Usage: mem_mixed_bench <size_mb> [read_write_ratio]
 * 
 * read_write_ratio:
 *   70 (default) - 70% reads, 30% writes (typical workload)
 *   50 - 50/50 balanced
 *   90 - 90% reads, 10% writes (read-heavy)
 * 
 * Output: JSON format with separate read/write statistics
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

static volatile int interrupted = 0;

typedef struct {
    uint64_t *latencies;
    size_t count;
    size_t capacity;
    uint64_t min_ns;
    uint64_t max_ns;
    uint64_t total_ns;
} latency_stats_t;

void signal_handler(int signo) {
    interrupted = 1;
}

static unsigned long rand_state = 12345;
static inline unsigned int fast_rand_range(unsigned int max) {
    rand_state = (rand_state * 1103515245 + 12345) & 0x7fffffff;
    return (unsigned int)(rand_state % max);
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

void init_stats(latency_stats_t *stats, size_t capacity) {
    stats->latencies = malloc(capacity * sizeof(uint64_t));
    stats->count = 0;
    stats->capacity = capacity;
    stats->min_ns = UINT64_MAX;
    stats->max_ns = 0;
    stats->total_ns = 0;
}

void add_latency(latency_stats_t *stats, uint64_t latency_ns) {
    if (stats->count < stats->capacity) {
        stats->latencies[stats->count++] = latency_ns;
    }
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

void print_results_json(latency_stats_t *read_stats, latency_stats_t *write_stats, 
                       size_t size_mb, int read_pct) {
    printf("{\n");
    printf("  \"test_type\": \"mixed_latency\",\n");
    printf("  \"size_mb\": %zu,\n", size_mb);
    printf("  \"read_write_ratio\": \"%d/%d\",\n", read_pct, 100 - read_pct);
    printf("  \"total_operations\": %zu,\n", read_stats->count + write_stats->count);
    
    // Read statistics
    if (read_stats->count > 0) {
        uint64_t avg_ns = read_stats->total_ns / read_stats->count;
        uint64_t p50_ns = get_percentile(read_stats, 50.0);
        uint64_t p95_ns = get_percentile(read_stats, 95.0);
        uint64_t p99_ns = get_percentile(read_stats, 99.0);
        
        printf("  \"read_stats\": {\n");
        printf("    \"count\": %zu,\n", read_stats->count);
        printf("    \"min_us\": %.2f,\n", read_stats->min_ns / 1000.0);
        printf("    \"max_us\": %.2f,\n", read_stats->max_ns / 1000.0);
        printf("    \"avg_us\": %.2f,\n", avg_ns / 1000.0);
        printf("    \"p50_us\": %.2f,\n", p50_ns / 1000.0);
        printf("    \"p95_us\": %.2f,\n", p95_ns / 1000.0);
        printf("    \"p99_us\": %.2f,\n", p99_ns / 1000.0);
        printf("    \"ops_per_sec\": %.0f\n", read_stats->count / ((double)read_stats->total_ns / 1000000000.0));
        printf("  },\n");
    }
    
    // Write statistics
    if (write_stats->count > 0) {
        uint64_t avg_ns = write_stats->total_ns / write_stats->count;
        uint64_t p50_ns = get_percentile(write_stats, 50.0);
        uint64_t p95_ns = get_percentile(write_stats, 95.0);
        uint64_t p99_ns = get_percentile(write_stats, 99.0);
        
        printf("  \"write_stats\": {\n");
        printf("    \"count\": %zu,\n", write_stats->count);
        printf("    \"min_us\": %.2f,\n", write_stats->min_ns / 1000.0);
        printf("    \"max_us\": %.2f,\n", write_stats->max_ns / 1000.0);
        printf("    \"avg_us\": %.2f,\n", avg_ns / 1000.0);
        printf("    \"p50_us\": %.2f,\n", p50_ns / 1000.0);
        printf("    \"p95_us\": %.2f,\n", p95_ns / 1000.0);
        printf("    \"p99_us\": %.2f,\n", p99_ns / 1000.0);
        printf("    \"ops_per_sec\": %.0f\n", write_stats->count / ((double)write_stats->total_ns / 1000000000.0));
        printf("  }\n");
    }
    
    printf("}\n");
}

int main(int argc, char *argv[]) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <size_mb> [read_percent]\n", argv[0]);
        fprintf(stderr, "read_percent: 70 (default, 70%% reads), 50, 90, etc.\n");
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
    
    // Parse read percentage
    int read_pct = 70;
    if (argc >= 3) {
        long read_long = strtol(argv[2], &endptr, 10);
        if (*endptr != '\0' || read_long < 0 || read_long > 100) {
            fprintf(stderr, "Error: Invalid read_percent (must be 0-100)\n");
            return 1;
        }
        read_pct = (int)read_long;
    }
    
    size_t total_size = MB_TO_BYTES(size_mb);
    size_t num_pages = total_size / PAGE_SIZE;
    
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);
    
    fprintf(stderr, "[mem_mixed_bench] Starting mixed workload latency test\n");
    fprintf(stderr, "[mem_mixed_bench] Size: %zu MB, Pages: %zu, Read/Write: %d/%d\n", 
            size_mb, num_pages, read_pct, 100 - read_pct);
    
    // Allocate memory
    char *memory = mmap(NULL, total_size, PROT_READ | PROT_WRITE,
                        MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        fprintf(stderr, "Error: Failed to mmap %zu MB: %s\n", size_mb, strerror(errno));
        return 1;
    }
    
    madvise(memory, total_size, MADV_RANDOM);
    
    // Initialize stats
    latency_stats_t read_stats, write_stats;
    init_stats(&read_stats, num_pages);
    init_stats(&write_stats, num_pages);
    
    if (read_stats.latencies == NULL || write_stats.latencies == NULL) {
        fprintf(stderr, "Error: Failed to allocate stats arrays\n");
        munmap(memory, total_size);
        return 1;
    }
    
    // Initial fill
    fprintf(stderr, "[mem_mixed_bench] Initial memory fill...\n");
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        char *page = memory + (i * PAGE_SIZE);
        memset(page, i % 256, PAGE_SIZE);
    }
    
    // Force initial swap-out
    fprintf(stderr, "[mem_mixed_bench] Forcing initial swap-out...\n");
    for (size_t i = 0; i < num_pages && !interrupted; i++) {
        madvise(memory + (i * PAGE_SIZE), PAGE_SIZE, MADV_PAGEOUT);
    }
    sleep(1);
    
    if (interrupted) {
        fprintf(stderr, "[mem_mixed_bench] Interrupted during setup\n");
        free(read_stats.latencies);
        free(write_stats.latencies);
        munmap(memory, total_size);
        return 1;
    }
    
    // Run mixed workload
    fprintf(stderr, "[mem_mixed_bench] Running mixed workload test...\n");
    
    struct timespec start, end;
    volatile char dummy = 0;
    size_t operations = num_pages * 2;  // 2x operations for good sample size
    
    for (size_t i = 0; i < operations && !interrupted; i++) {
        // Random page
        size_t page_idx = fast_rand_range(num_pages);
        char *page = memory + (page_idx * PAGE_SIZE);
        
        // Decide read or write
        int is_read = (fast_rand_range(100) < (unsigned int)read_pct);
        
        clock_gettime(CLOCK_MONOTONIC, &start);
        
        if (is_read) {
            // Read operation (may cause page fault)
            dummy += page[0];
        } else {
            // Write operation (may cause page fault + page dirty)
            page[0] = (char)(i % 256);
            // Force page-out to measure write latency
            madvise(page, PAGE_SIZE, MADV_PAGEOUT);
        }
        
        clock_gettime(CLOCK_MONOTONIC, &end);
        
        uint64_t latency = timespec_diff_ns(&start, &end);
        
        if (is_read) {
            add_latency(&read_stats, latency);
        } else {
            add_latency(&write_stats, latency);
        }
        
        if ((i + 1) % REPORT_INTERVAL == 0) {
            fprintf(stderr, "[mem_mixed_bench] Operations: %zu/%zu (R:%zu W:%zu)\n", 
                    i + 1, operations, read_stats.count, write_stats.count);
        }
    }
    
    if (interrupted) {
        fprintf(stderr, "[mem_mixed_bench] Interrupted during test\n");
    }
    
    fprintf(stderr, "[mem_mixed_bench] Test complete, calculating statistics...\n");
    
    // Calculate and print statistics
    calculate_statistics(&read_stats);
    calculate_statistics(&write_stats);
    print_results_json(&read_stats, &write_stats, size_mb, read_pct);
    
    // Cleanup
    free(read_stats.latencies);
    free(write_stats.latencies);
    munmap(memory, total_size);
    
    return interrupted ? 1 : 0;
}
