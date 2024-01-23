#ifndef __USERPROG_PROCESS_H
#define __USERPROG_PROCESS_H

#include "../thread/thread.h"
#include "stdint.h"

// 默认优先级
#define default_prio 31

// (0xc0000000 - 1)为用户空间最高地址, 往上为内核地址
// (0xc0000000 - 0x1000) 为栈顶的下边界, 0x1000 = 4096 = 4k
#define USER_STACK3_VADDR  (0xc0000000 - 0x1000)

// 用户进程起始地址, 这里采用 Linux 的入口地址
#define USER_VADDR_START   0x8048000

/* 创建用户进程 */
void process_execute(void* filename, char* name);

/* 构建用户进程初始上下文信息(填充用户进程的 intr_stack) */
void start_process(void* filename_);

/* 激活线程或进程的页表, 更新 tss 中的 esp0 为进程的特权级0的栈 */
void process_activate(struct task_struct* p_thread);

/* 激活页表(更新 cr3 指向的页目录表, 每个进程有自己的页目录表) */
void page_dir_activate(struct task_struct* p_thread);

/* 创建页目录表, 将当前页表的表示内核空间的 pde 复制,
 * 成功则返回页目录的虚拟地址, 否则返回 -1 */
uint32_t* create_page_dir(void);

/* 创建用户进程虚拟地址位图 */
void create_user_vaddr_bitmap(struct task_struct* user_prog);

#endif

