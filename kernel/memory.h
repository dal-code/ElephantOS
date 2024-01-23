#ifndef __KERNEL_MEMORY_H
#define __KERNEL_MEMORY_H

#include "stdint.h"
#include "bitmap.h"

/* 内存池标记， 用于判断用哪个内存池 */
enum pool_flags {
    PF_KERNEL = 1,      // 内核物理内存池
    PF_USER = 2         // 用户物理内存池
};
//--------------页表 属性---------------------
#define	 PG_P_1	  1	    // 页表项或页目录项存在属性位 1
#define	 PG_P_0	  0	    // 页表项或页目录项存在属性位 0
#define	 PG_RW_R  0	    // R/W 属性位值, 读/执行     00
#define	 PG_RW_W  2	    // R/W 属性位值, 读/写/执行  10
#define	 PG_US_S  0	    // U/S 属性位值, 系统级      000
#define	 PG_US_U  4	    // U/S 属性位值, 用户级      100

/* 用于虚拟地址管理 */
struct virtual_addr {
    struct bitmap vaddr_bitmap;     // 虚拟地址用到的位图结构
    uint32_t vaddr_start;           // 虚拟地址起始地址
};


extern struct pool kernel_pool, user_pool;

void mem_init(void);


/* 从内核物理内存池中申请 pg_cnt 页内存, 成功则返回其虚拟地址, 失败则返回 NULL */
void* get_kernel_pages(uint32_t pg_cnt);

/* 在用户空间中申请 pg_cnt个4k 内存, 并返回其虚拟地址 */
void* get_user_pages(uint32_t pg_cnt);

/* 分配 pg_cnt 个页空间, 成功则返回起始虚拟地址, 失败时返回 NULL 空间的虚拟地址和物理地址已经完成了映射*/
void* malloc_page(enum pool_flags pf, uint32_t pg_cnt);

/* 得到虚拟地址vaddr对应的pte指针 */
uint32_t* pte_ptr(uint32_t vaddr);

/* 得到虚拟地址vaddr对应的pde指针 */
uint32_t* pde_ptr(uint32_t vaddr);

/* 得到虚拟地址映射到的物理地址 */
uint32_t addr_v2p(uint32_t vaddr);

/* 将地址 vaddr 与 pf 池中的物理地址关联, 仅支持一页空间分配 */
void* get_a_page(enum pool_flags pf, uint32_t vaddr);




void malloc_init(void);





#endif




