/*
 * Minimal reproducer: on armv7/musl a debugger cannot unwind a thread that is
 * parked in a blocking syscall.
 *
 * Every thread here enters its blocking call through a three-deep call chain,
 * so a working backtrace must show
 *
 *     poll / nanosleep / pthread_cond_timedwait
 *       <- park_in_*
 *       <- level_three <- level_two <- level_one <- worker <- start
 *
 * On x86_64 that is exactly what gdb prints. On armv7 the backtrace ends
 * inside musl after one or two frames, and everything above - the whole
 * application part - is lost.
 *
 * Cause: musl's hand-written syscall assembly (src/thread/arm/syscall_cp.s)
 * carries no .cfi_* directives, so no FDE covers __cp_begin. Every blocking
 * call goes through it, which means every sleeping thread is unwindable.
 * musl itself does not need that information - unlike glibc it implements
 * pthread cancellation without stack unwinding - so nothing is broken for the
 * library, only for debuggers.
 *
 * Built with -funwind-tables, so the application's own frames DO have unwind
 * information. The gap is inside libc, not in this program.
 */

#include <pthread.h>
#include <poll.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#define NOINLINE __attribute__((noinline))

enum { PARK_POLL = 0, PARK_SLEEP = 1, PARK_COND = 2, PARK_KINDS = 3 };

static pthread_mutex_t g_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;

static NOINLINE void park_in_poll(void)
{
	poll(NULL, 0, -1);
}

static NOINLINE void park_in_sleep(void)
{
	struct timespec how_long;
	how_long.tv_sec = 3600;
	how_long.tv_nsec = 0;
	nanosleep(&how_long, NULL);
}

static NOINLINE void park_in_cond(void)
{
	struct timespec deadline;
	clock_gettime(CLOCK_REALTIME, &deadline);
	deadline.tv_sec += 3600;

	pthread_mutex_lock(&g_mutex);
	pthread_cond_timedwait(&g_cond, &g_mutex, &deadline);
	pthread_mutex_unlock(&g_mutex);
}

static NOINLINE void level_three(int kind)
{
	switch (kind) {
	case PARK_POLL:
		park_in_poll();
		break;
	case PARK_SLEEP:
		park_in_sleep();
		break;
	default:
		park_in_cond();
		break;
	}
}

static NOINLINE void level_two(int kind)
{
	level_three(kind);
}

static NOINLINE void level_one(int kind)
{
	level_two(kind);
}

static void *worker(void *arg)
{
	level_one((int)(long)arg);
	return NULL;
}

/*
 * Empty on purpose. main calls it once every worker has reached its blocking
 * call, so a debugger has a deterministic place to stop:  break parked
 */
static NOINLINE void parked(void)
{
	/*
	 * The barrier is what keeps this function alive. Empty, it has no
	 * observable effect, and gcc -O2 removes both the call and the symbol -
	 * noinline only prevents inlining. "break parked" then fails silently
	 * and the following "continue" never returns.
	 */
	__asm__ __volatile__("" ::: "memory");
}

int main(void)
{
	pthread_t threads[PARK_KINDS];
	long kind;

	for (kind = 0; kind < PARK_KINDS; kind++) {
		if (pthread_create(&threads[kind], NULL, worker, (void *)kind) != 0) {
			fprintf(stderr, "pthread_create failed\n");
			return 1;
		}
	}

	/* Give the workers a moment to reach their blocking call. */
	sleep(1);
	printf("pid %ld, %d worker threads parked\n", (long)getpid(), PARK_KINDS);
	fflush(stdout);
	parked();

	/* Park the main thread the same way, through the same chain. */
	level_one(PARK_SLEEP);
	return 0;
}
