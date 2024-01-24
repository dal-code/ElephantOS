#include "memory.h"
#include "stdint.h"
#include "print.h"
#include "global.h"
#include "debug.h"
#include "string.h"
#include "../lib/kernel/bitmap.h"
#include "../thread/thread.h"
#include "../thread/sync.h"
#include "interrupt.h"


/************************** 位图地址 *******************************************
 * 因为 0xc009f000 是内核主线程栈顶, 0xc009e000 是内核主线程的pcb(pcb占用1页 = 4k).
 * 一个页框大小的位图可表示128M内存, 位图位置安排在地址0xc009a000,
 * 这样本系统最大支持4个页框的位图, 即512M
******************************************************************************/
#define MEM_BITMAP_BASE 0xc009a000

#define PDE_IDX(addr) ((addr & 0xffc00000) >> 22)   // 返回虚拟地址高10位, 用于定位pde
#define PTE_IDX(addr) ((addr & 0x003ff000) >> 12)   // 返回虚拟地址中间10位, 用于定位pte

/* 0xc0000000是内核从虚拟地址3G起. 0x100000意指跨过低端1M内存, 使虚拟地址在逻辑上连续 */
#define K_HEAP_START 0xc0100000

/* 内存池结构, 生成两个实例用于管理内核内存池和用户内存池 */
struct pool {
    struct bitmap pool_bitmap;      // 本内存池用到的位图结构, 用于管理物理内存
    uint32_t phy_addr_start;        // 本内存池所管理物理内存的起始地址
    uint32_t pool_size;             // 本内存池字节容量
    struct lock lock;               //申请内存时互斥
};

struct pool kernel_pool, user_pool; // 生成内核物理内存池和用户物理内存池
struct virtual_addr kernel_vaddr;   // 此结构用来给内核分配虚拟地址

struct arena {
    struct mem_block_desc* desc;
    uint32_t cnt;
    bool large;
};

// 内核内存块描述符数组  用户的在PCB中
struct mem_block_desc k_block_descs[DESC_CNT];  

/* 为 malloc 做准备 */
void block_desc_init(struct mem_block_desc* desc_array) {
    uint16_t desc_idx, block_size = 16;

    // 初始化每个 mem_block_desc 描述符
    for(desc_idx = 0; desc_idx < DESC_CNT; desc_idx++) {
        desc_array[desc_idx].block_size = block_size;

         // 初始化 arena 中的内存块数量
         // blocks_per_arena(本 arena 中可容纳此 mem_block 的数量) = 
         // (每页大小 - arena 元信息) /  内存块规格
         desc_array[desc_idx].blocks_per_arena = (PG_SIZE - sizeof(struct arena)) / block_size;
         list_init(&desc_array[desc_idx].free_list);
         block_size *= 2;   // 更新为下一个规格内存块
    }
}

/* 返回 arena 中第 idx 个内存块的地址 */
static struct mem_block* arena2block(struct arena* a, uint32_t idx) {
    // 在arena所指的的页框中，跳过元信息部分，再用idx乘以arena中内存块的大小
    return (struct mem_block*) ((uint32_t) a + sizeof(struct arena) + idx * a->desc->block_size);
}


/* 返回内存块 b 所在的 arena地址 */
static struct arena* block2arena(struct mem_block* b) {
    // 将 7 种类型的内存块转换为内存块所在的arena，由于此类内存块所在的arena占据完整的1页，所以前20位是一样的
    return (struct arena*) ((uint32_t) b & 0xfffff000);
}


/* 在堆中申请 size 字节内存 */
void* sys_malloc(uint32_t size) {
    enum pool_flags PF;
    struct pool* mem_pool;
    uint32_t pool_size;
    struct mem_block_desc* descs;
    struct task_struct* cur_thread = running_thread();

    // 判断用哪个内存池
    if(cur_thread->pgdir == NULL) {
        // 若为内核线程
        PF = PF_KERNEL;
        pool_size = kernel_pool.pool_size;
        mem_pool = &kernel_pool;
        descs = k_block_descs;

    } else {
        // 用户进程 pcb 中的 pgdir 会在为其分配页表时创建
        PF = PF_USER;
        pool_size = user_pool.pool_size;
        mem_pool = &user_pool;
        descs = cur_thread->u_block_desc;
    }

    // 若申请的内存不在内存池容量范围内则直接返回 NULL
    if(!(size > 0 && size < pool_size)) {
        return NULL;
    }

    struct arena* a;
    struct mem_block* b;
    lock_acquire(&mem_pool->lock);

    // 超过最大内存块 1024, 就分配页框
    if(size > 1024) {
        // 向上取整, 得到分配的页框数量
        uint32_t page_cnt = DIV_ROUND_UP(size + sizeof(struct arena), PG_SIZE);
    
        a = malloc_page(PF, page_cnt);

        if(a != NULL) {
            memset(a, 0, page_cnt * PG_SIZE);   // 将分配的内存清零
            // 对于分配的大块页框, 将 desc 置为 NULL, cnt 置为页框数, large 置为 true
            a->desc = NULL;
            a->cnt = page_cnt;
            a->large = true;
            lock_release(&mem_pool->lock);
            return (void*) (a + 1);             // 跨过 arena 大小, 把剩下的内存返回
        
        } else {
            lock_release(&mem_pool->lock);
            return NULL;
        }

    } else {
        // 若申请的内存小于等于 1024, 可在各种规格的 mem_block_desc 中去适配
        uint8_t desc_idx;

        // 从内存块描述符中匹配合适的内存块规格
        for(desc_idx = 0; desc_idx < DESC_CNT; desc_idx++) {
            if(size <= descs[desc_idx].block_size) {
                // 从小往大, 找到后退出
                break;
            }
        }

        // 若 mem_block_desc 的 free_list 中已经没有可用的 mem_block
        // 就创建新的 arena 提供 mem_block
        if(list_empty(&descs[desc_idx].free_list)) {
            a = malloc_page(PF, 1);     // 分配 1 页框做为 arena
            if(a == NULL) {
                lock_release(&mem_pool->lock);
                return NULL;
            }
            memset(a, 0, PG_SIZE);      // 清空申请的页框

            // 对于分配的小块内存, 将 desc 置为相应内存块描述符
            // cnt 置为 arena 可用的内存块数, large 置为 false
            a->desc = &descs[desc_idx];
            a->large = false;
            a->cnt = descs[desc_idx].blocks_per_arena;
            uint32_t block_idx;

            enum intr_status old_status = intr_disable();

            // 开始将 arena 拆分成内存块, 并添加到内存块描述符的 free_list 中
            for(block_idx = 0; block_idx < descs[desc_idx].blocks_per_arena; block_idx++) {
                b = arena2block(a, block_idx);
                ASSERT(!elem_find(&a->desc->free_list, &b->free_elem));
                list_append(&a->desc->free_list, &b->free_elem);
            }
            intr_set_status(old_status);
        }

        // 开始分配内存块
        // 从 free_list 弹出一个内存块(mem_block)中的list_elem, 获取 mem_block 的地址
        b = elem2entry(struct mem_block, free_elem, list_pop(&(descs[desc_idx].free_list)));
        memset(b, 0, descs[desc_idx].block_size);

        a = block2arena(b);     // 获取内存块 b 所在的 arena
        a->cnt--;               // 将此 arena 中的空闲块数减 1
        lock_release(&mem_pool->lock);
        return (void*) b;
    }
}


/* 
 * 在pf表示的虚拟内存池中申请 pg_cnt 个虚拟页,
 * 成功则返回虚拟页的起始地址, 失败则返回 NULL 
 */
static void* vaddr_get(enum pool_flags pf, uint32_t pg_cnt) {
    int vaddr_start = 0, bit_idx_start = -1;
    uint32_t cnt = 0;
    if (pf == PF_KERNEL) {
        bit_idx_start = bitmap_scan(&kernel_vaddr.vaddr_bitmap, pg_cnt);    // 获取申请的虚拟页的位起始值
        if (bit_idx_start == -1) {
            return NULL;
        }

        // 将位起始值开始连续置1, 直到设置完需要的页位置
        while (cnt < pg_cnt) {
            bitmap_set(&kernel_vaddr.vaddr_bitmap, bit_idx_start + cnt, 1);
            cnt++;
        }
        // 获取起始页的虚拟地址
        vaddr_start = kernel_vaddr.vaddr_start + bit_idx_start * PG_SIZE;

    } else {
        // 用户内存池
        struct task_struct* cur = running_thread();
        // 在用户进程的虚拟地址位图申请 pg_cnt 个页
        bit_idx_start = bitmap_scan(&cur->userprog_vaddr.vaddr_bitmap, pg_cnt);
        if(bit_idx_start == -1) {
            return NULL;
        }

        while(cnt < pg_cnt) {
            bitmap_set(&cur->userprog_vaddr.vaddr_bitmap, bit_idx_start + (cnt++), 1);
        }
        // 得到虚拟地址起始地址
        vaddr_start = cur->userprog_vaddr.vaddr_start + bit_idx_start * PG_SIZE;
        // (0xc0000000 - PG_SIZE)做为用户3级栈已经在 start_process 被分配
        ASSERT((uint32_t) vaddr_start < (0xc0000000 - PG_SIZE));
    }

    return (void*) vaddr_start;
}



/* 得到虚拟地址vaddr计算得到对应的pte指针(虚拟地址) ，这个虚拟地址是vaddr对应页框（pte）的物理地址*/
uint32_t* pte_ptr(uint32_t vaddr) {
    // 先访问到页表自己
    // 再用页目录项 pde（页目录内页表的索引）作为pte的索引访问到页表
    // 再用pte的索引作为页内偏移

    // 第一步：0xffc00000 是取出第1023个页目录项进行索引, 其实就是页目录表的物理地址
    // 第二步：((vaddr & 0xffc00000) >> 10) 是将原来vaddr的前10位取出, 放在中间10位的位置上 用来获取 pte 的
    // 第三步：PTE_IDX(vaddr) * 4 会被当作物理偏移直接加上, 而不会像其前面10位会被cpu自动*4再加上, 所以这里手动*4, 获取PTE索引, 得到PTE物理地址
    uint32_t* pte = (uint32_t*) (0xffc00000 + ((vaddr & 0xffc00000) >> 10) + PTE_IDX(vaddr) * 4);
    return pte;  
}


/* 得到虚拟地址vaddr计算得到对应的pde的指针(虚拟地址)，vaddr的pde物理地址 */
uint32_t* pde_ptr(uint32_t vaddr) {
    // 0xfffff 用来访问到页表本身所在的地址
    // 前10位是1023, 是页目录表的物理地址
    // 中10位是1023, 索引到的还是页目录表的物理地址
    // 后12位是addr的前10位*4, 也就是页目录表的索引
    uint32_t* pde = (uint32_t*) ((0xfffff000) + PDE_IDX(vaddr) * 4);
    return pde;
}


/* 
 * 在 m_pool 指向的物理内存池中分配 1 个物理页,
 * 成功则返回页框的物理地址, 失败则返回 NULL 
 * */
static void* palloc(struct pool* m_pool) {
    // 扫描或设置位图要保证原子操作
    int bit_idx = bitmap_scan(&m_pool->pool_bitmap, 1);     // 找一个物理页面, 位图中1位表示实际1页地址
    if (bit_idx == -1) {
        return NULL;
    }
    bitmap_set(&m_pool->pool_bitmap, bit_idx, 1);           // 将此位的 bit_idx 置 1  
    uint32_t page_phyaddr = ((bit_idx * PG_SIZE) + m_pool->phy_addr_start); // 物理内存池起始地址 + 页偏移 = 页地址
    return (void*) page_phyaddr;
}

/* 页表中添加虚拟地址 _vaddr 与物理地址 _page_phyaddr 的映射 */
static void page_table_add(void* _vaddr, void* _page_phyaddr) {
    uint32_t vaddr = (uint32_t) _vaddr;
    uint32_t page_phyaddr = (uint32_t) _page_phyaddr;
    uint32_t* pde = pde_ptr(vaddr);
    uint32_t* pte = pte_ptr(vaddr);

    /************************   注意   **************************************************
    * 执行*pte, 会访问到空的pde。所以确保 pde 创建完成后才能执行 *pte,
    * 否则会引发page_fault。因此在 *pde 为0时, *pte 只能出现在下面 else 语句块中的* pde 后面。
    * ***********************************************************************************/

    // 先在页目录内判断目录项的p位, 若为1, 则表示该表已存在
    if (*pde & 0x00000001) {
        // 页目录项和页表项的第0位为P, 此处判断目录项是否存在
        ASSERT(!(*pte & 0x00000001));       // 此时pte应该不存在

        // 只要是创建页表, pte就应该不存在, 多判断一下放心
        if (!(*pte & 0x00000001)) {
            *pte = (page_phyaddr | PG_US_U | PG_RW_W | PG_P_1);     // 创建pte
        
        } else {
            // 目前执行不到这里
            PANIC("pte repeat");
            *pte = (page_phyaddr | PG_US_U | PG_RW_W | PG_P_1);
        }

    } else {
        // 页目录项不存在, 所以要先创建页目录项再创建页表项
        // 页表中用到的页框一律从内核空间分配
        // pte 和 pde 都是真实的 pde 和 pte物理地址对应的虚拟地址 

        // pde_phyaddr是物理地址 这个物理地址是页表的物理地址
        uint32_t pde_phyaddr = (uint32_t) palloc(&kernel_pool);
        *pde = (pde_phyaddr | PG_US_U | PG_RW_W | PG_P_1);

        /* 分配到的物理页地址 pde_phyaddr 对应的物理内存清 0,
        * 避免里面的陈旧数据变成了页表项, 从而让页表混乱.
        * 访问到 pde 对应的物理地址, 用 pte 取高20位便可.
        * 因为 pte 是基于该 pde 对应的物理地址再寻址,
        * 把低12位置0便是该pde对应的物理页的起始"虚拟地址"
        * */

        // 把分配到的物理页地址 pde_phyaddr(物理地址) 对应的物理内存清 0  pde中的物理地址就是pte所在页表的物理地址，
        // (int) pte & 0xfffff000: vaddr 所在页表的虚拟地址, 即 pde_phyaddr 的虚拟地址（pte是虚拟地址页框的物理地址，高20位就是页表的物理地址）
        memset((void*) ((int) pte & 0xfffff000), 0, PG_SIZE);

        ASSERT(!(*pte & 0x00000001));
        *pte = (page_phyaddr | PG_US_U | PG_RW_W | PG_P_1);
    }
}


/* 在用户空间中申请 4k 内存, 并返回其虚拟地址 */
void* get_user_pages(uint32_t pg_cnt) {
    lock_acquire(&user_pool.lock);
    // 从用户物理内存池申请内存, 从当前线程的虚拟内存池申请虚拟内存, 
    // 将申请的虚拟内存与物理内存做映射, 返回起始虚拟地址
    void* vaddr = malloc_page(PF_USER, pg_cnt);
    //内存空间清零
    memset(vaddr, 0, pg_cnt * PG_SIZE);
    lock_release(&user_pool.lock);
    return vaddr;
}



/* 从内核物理内存池中申请 pg_cnt 页内存, 成功则返回其虚拟地址, 失败则返回 NULL */
void* get_kernel_pages(uint32_t pg_cnt) {
    void* vaddr = malloc_page(PF_KERNEL, pg_cnt);
    if (vaddr != NULL) {
        // 若分配的地址不为空, 将页框清 0 后返回
        memset(vaddr, 0, pg_cnt * PG_SIZE);
    }
    return vaddr;
}


/* 将地址 vaddr 与 pf 池中的物理地址关联, 仅支持一页空间分配 */
void* get_a_page(enum pool_flags pf, uint32_t vaddr) {
    struct pool* mem_pool = pf & PF_KERNEL ? &kernel_pool : &user_pool;
    lock_acquire(&mem_pool->lock);

    // 先将虚拟地址对应的位图置 1
    struct task_struct* cur = running_thread();
    int32_t bit_idx = -1;

    if(cur->pgdir != NULL && pf == PF_USER) {
        // 若当前是用户进程申请用户内存, 就修改用户进程自己的虚拟地址位图
        // bit_idx = (虚拟地址 - 虚拟地址起始地址) / 每位大小
        bit_idx = (vaddr - cur->userprog_vaddr.vaddr_start) / PG_SIZE;
        ASSERT(bit_idx > 0);
        bitmap_set(&cur->userprog_vaddr.vaddr_bitmap, bit_idx, 1);

    } else if(cur->pgdir == NULL && pf == PF_KERNEL) {
        // 如果是内核线程申请内核内存, 就修改 kernel_vaddr
        bit_idx = (vaddr - kernel_vaddr.vaddr_start) / PG_SIZE;
        ASSERT(bit_idx > 0);
        bitmap_set(&kernel_vaddr.vaddr_bitmap, bit_idx, 1);

    } else {
        PANIC("get_a_page: not allow kernel alloc userspace or user alloc kernelspace by get_a_page");
    }

    // 在物理内存池中申请一个物理页
    void* page_phyaddr = palloc(mem_pool);
    if(page_phyaddr == NULL) {
        return NULL;
    }
    // 将虚拟地址与物理地址做映射
    page_table_add((void*) vaddr, page_phyaddr);
    lock_release(&mem_pool->lock);
    return (void*) vaddr;
}


/* 得到虚拟地址映射到的物理地址 */
uint32_t addr_v2p(uint32_t vaddr) {
    // 得到虚拟地址对应的 pte, pte中记录了物理页框地址
    uint32_t* pte = pte_ptr(vaddr);
    // (*pte)的值是页表所在的物理页框地址,
    // 去掉其低12位的页表项属性 + 虚拟地址 vaddr 的低12位(偏移地址)
    return ((*pte & 0xfffff000) + (vaddr & 0x00000fff));
}


/* 分配 pg_cnt 个页空间, 成功则返回起始虚拟地址, 失败时返回 NULL */
void* malloc_page(enum pool_flags pf, uint32_t pg_cnt) {
    ASSERT(pg_cnt > 0 && pg_cnt < 3840);

    /***********  malloc_page 的原理是三个动作的合成:   ***********
         1. 通过 vaddr_get 在虚拟内存池中申请虚拟地址
         2. 通过 palloc 在物理内存池中申请物理页
         3. 通过 page_table_add 将以上得到的虚拟地址和物理地址在页表中完成映射
   ***************************************************************/
    void* vaddr_start = vaddr_get(pf, pg_cnt);
    if (vaddr_start == NULL) {
        return NULL;
    }

    uint32_t vaddr = (uint32_t) vaddr_start;
    uint32_t cnt = pg_cnt;
    struct pool* mem_pool = pf & PF_KERNEL ? &kernel_pool : &user_pool;

    // 因为虚拟地址是连续的, 但物理地址不连续, 所以逐个映射
    while ((cnt--) > 0) {
        void* page_phyaddr = palloc(mem_pool);
        if (page_phyaddr == NULL) {
            // 失败时要将曾经已申请的虚拟地址和
            // 物理页全部回滚, 在将来完成内存回收时再补充
            return NULL;
        }
        page_table_add((void*) vaddr, page_phyaddr);    // 在表中逐个做映射
        vaddr += PG_SIZE;                               // 下一个虚拟页
    }
    return vaddr_start;
}


/* 将物理地址 pg_phy_addr 回收到物理内存池 */
void pfree(uint32_t pg_phy_addr) {
    struct pool* mem_pool;
    uint32_t bit_idx = 0;
    if(pg_phy_addr >= user_pool.phy_addr_start) {
        // 用户物理内存池
        mem_pool = &user_pool;
        bit_idx = (pg_phy_addr - user_pool.phy_addr_start) / PG_SIZE;
    } else {
        // 内核物理内存池
        mem_pool = &kernel_pool;
        bit_idx = (pg_phy_addr - kernel_pool.phy_addr_start) / PG_SIZE;
    }
    bitmap_set(&mem_pool->pool_bitmap, bit_idx, 0);     // 将位图中该位清 0
}

/* 去掉页表中虚拟地址 vaddr 的映射, 只去掉 vaddr 对应的 pte */
static void page_table_pte_remove(uint32_t vaddr) {
    uint32_t* pte = pte_ptr(vaddr);
    *pte &= ~PG_P_1;                                        // 将页表项 pte 的 P 位置 0
    asm volatile("invlpg %0" : : "m"(vaddr) : "memory");    // 更新 tlb
}


/* 在虚拟地址池中释放以 _vaddr 起始的连续 pg_cnt 个虚拟页地址 */
static void vaddr_remove(enum pool_flags pf, void* _vaddr, uint32_t pg_cnt) {
    uint32_t bit_idx_start = 0, vaddr = (uint32_t) _vaddr, cnt = 0;

    if(pf == PF_KERNEL) {
        // 内核虚拟内存池
        bit_idx_start = (vaddr - kernel_vaddr.vaddr_start) / PG_SIZE;
        while(cnt < pg_cnt) {
            bitmap_set(&kernel_vaddr.vaddr_bitmap, bit_idx_start + (cnt++), 0);
        }

    } else {
        // 用户虚拟内存池
        struct task_struct* cur_thread = running_thread();
        bit_idx_start = (vaddr - cur_thread->userprog_vaddr.vaddr_start) / PG_SIZE;
        while(cnt < pg_cnt) {
            bitmap_set(&cur_thread->userprog_vaddr.vaddr_bitmap, bit_idx_start + (cnt++), 0);
        }
    }
}

/* 释放以虚拟地址 vaddr 为起始的 cnt 个物理页框 */
void mfree_page(enum pool_flags pf, void* _vaddr, uint32_t pg_cnt) {
    uint32_t pg_phy_addr;
    uint32_t vaddr = (uint32_t) _vaddr, page_cnt = 0;
    ASSERT(pg_cnt >= 1 && vaddr % PG_SIZE == 0);
    // 获取虚拟地址 vaddr 对应的物理地址
    pg_phy_addr = addr_v2p(vaddr);

    // 确保待释放的物理内存在低端 1MB+1KB 大小的页目录 + 1KB 大小的页表地址外
    ASSERT((pg_phy_addr % PG_SIZE) == 0 && pg_phy_addr >= 0x102000);

    // 判断 pg_phy_addr 属于用户物理内存池还是内核物理内存池
    if(pg_phy_addr >= user_pool.phy_addr_start) {
        // 位于用户物理内存池
        vaddr -= PG_SIZE;
        while(page_cnt < pg_cnt) {
            vaddr += PG_SIZE;
            pg_phy_addr = addr_v2p(vaddr);

            // 确保物理地址属于用户物理地址池
            ASSERT((pg_phy_addr % PG_SIZE) == 0 && pg_phy_addr >= user_pool.phy_addr_start);
            
            // 先将对应的物理页框归还到内存池
            pfree(pg_phy_addr);

            // 再从页表中清除此虚拟地址所在的页表项 pte
            page_table_pte_remove(vaddr);

            page_cnt++;
        }
        // 清空虚拟地址的位图中的相应位
        vaddr_remove(pf, _vaddr, pg_cnt);

    } else {
        // 位于内核物理内存池
        vaddr -= PG_SIZE;
        while (page_cnt < pg_cnt) {
            vaddr += PG_SIZE;
            pg_phy_addr = addr_v2p(vaddr);
            
            // 确保待释放的物理内存只属于内核物理地址池
            ASSERT((pg_phy_addr % PG_SIZE) == 0 && 
                    pg_phy_addr >= kernel_pool.phy_addr_start && 
                    pg_phy_addr < user_pool.phy_addr_start);

            // 先将对应的物理页框归还到内存池
            pfree(pg_phy_addr);

            // 再从页表中清除此虚拟地址所在的页表框 pte
            page_table_pte_remove(vaddr);

            page_cnt++;
        }
        // 清空虚拟地址的位图中的相应位
        vaddr_remove(pf, _vaddr, pg_cnt);
    }
}


/* 回收内存 ptr */
void sys_free(void* ptr) {
    ASSERT(ptr != NULL);

    if(ptr != NULL) {
        enum pool_flags PF;
        struct pool* mem_pool;

        // 判断是线程, 还是进程
        if(running_thread()->pgdir == NULL) {
            ASSERT((uint32_t) ptr >= K_HEAP_START);
            PF = PF_KERNEL;
            mem_pool = &kernel_pool;

        } else {
            PF = PF_USER;
            mem_pool = &user_pool;
        }

        lock_acquire(&mem_pool->lock);
        struct mem_block* b = ptr;
        // 把 mem_block 转换成 arena, 获取元信息
        struct arena* a = block2arena(b);

        ASSERT(a->large == 0 || a->large == 1);
        if(a->desc == NULL && a->large == true) {
            // 大于 1024 的内存
            mfree_page(PF, a, a->cnt);

        } else {
            // 小于等于 1024 的内存块
            // 先将内存块回收到 free_list
            list_append(&a->desc->free_list, &b->free_elem);

            // 再判断此 arena 中的内存块是否都是空闲, 如果是就释放 arena(整个arena)
            if(++a->cnt == a->desc->blocks_per_arena) {
                uint32_t block_idx;
                for(block_idx = 0; block_idx < a->desc->blocks_per_arena; block_idx++) {
                    struct mem_block* b = arena2block(a, block_idx);
                    ASSERT(elem_find(&a->desc->free_list, &b->free_elem));
                    list_remove(&b->free_elem);
                }
                mfree_page(PF, a, 1);
            }
        }
        lock_release(&mem_pool->lock);
    }
}



/* 初始化内存池 */
static void mem_pool_init(uint32_t all_mem) {
    put_str("    mem_pool_init start\n");

    // 页表大小 ＝ 1页的页目录表 ＋第 0 和第 768 个页目录项指向同一个页表, 之前创建页表的时候, 挨着页目录表创建了768-1022总共255个页表 + 上页目录的1页大小, 就是256
    // 第 769~1022 个页目录项共指向 254 个页表, 共 256 个页框
    uint32_t page_table_size = PG_SIZE * 256;           // 记录页目录表和页表占用的字节大小

    uint32_t used_mem = page_table_size + 0x100000;     // 当前已经使用的内存字节数, 1M部分已经使用了, 1M往上是页表所占用的空间
    uint32_t free_mem = all_mem - used_mem;             // 剩余可用内存字节数
    uint16_t all_free_pages = free_mem / PG_SIZE;       // 所有可用的页
    // 1页为 4KB, 不管总内存是不是 4k 的倍数, 对于以页为单位的内存分配策略, 不足 1 页的内存不用考虑了

    uint16_t kernel_free_pages = all_free_pages / 2;    // 分配给内核的空闲物理页
    uint16_t user_free_pages = all_free_pages - kernel_free_pages;

    // 为简化位图操作, 余数不处理, 坏处是这样做会丢内存。好处是不用做内存的越界检查, 因为位图表示的内存少于实际物理内存。
    uint32_t kbm_length = kernel_free_pages / 8;        // Kernel Bitmap的长度, 位图中的一位表示一页, 以字节为单位, 也就是8页表示1字节的位图
    uint32_t ubm_length = user_free_pages / 8;          // User Bitmap 的长度

    uint32_t kp_start = used_mem;                                   // kernel pool start, 内核内存池起始地址 0x200000
    uint32_t up_start = kp_start + kernel_free_pages * PG_SIZE;     // 内核已使用的 + 没使用的, 就是分配给内核的全部内存, 剩下给用户

    kernel_pool.phy_addr_start = kp_start;
    user_pool.phy_addr_start = up_start;

    kernel_pool.pool_size = kernel_free_pages * PG_SIZE;            // 内存池里存放的是空闲的内存, 所以用可用内存大小填充
    user_pool.pool_size = user_free_pages * PG_SIZE;

    kernel_pool.pool_bitmap.btmp_bytes_len = kbm_length; // 位图的长度
    user_pool.pool_bitmap.btmp_bytes_len = ubm_length; 

    /*********    内核内存池和用户内存池位图   ***********
    *   位图是全局的数据, 长度不固定。
    *   全局或静态的数组需要在编译时知道其长度，
    *   而我们需要根据总内存大小算出需要多少字节。
    *   所以改为指定一块内存来生成位图.
    *   ************************************************/
    // 内核使用的最高地址是0xc009f000, 这是主线程的栈地址.(内核的大小预计为70K左右)
    // 32M内存占用的位图是2k. 内核内存池的位图先定在 MEM_BITMAP_BASE(0xc009a000)处.

    kernel_pool.pool_bitmap.bits = (void*) MEM_BITMAP_BASE;
    /* 用户内存池的位图紧跟在内核内存池位图之后 */
    user_pool.pool_bitmap.bits = (void*) (MEM_BITMAP_BASE + kbm_length);

    // 输出内存池信息
    put_str("        kernel_pool_bitmap_start: ");
    put_int((int) kernel_pool.pool_bitmap.bits);

    put_str(" kernel_pool_phy_addr_start: ");
    put_int(kernel_pool.phy_addr_start);

    put_str("\n");

    put_str("        user_pool_bitmap_start: ");
    put_int((int) user_pool.pool_bitmap.bits);

    put_str(" user_pool_phy_addr_start: ");
    put_int(user_pool.phy_addr_start);


    put_str("\n");

    // 将位图置 0
    bitmap_init(&kernel_pool.pool_bitmap);
    bitmap_init(&user_pool.pool_bitmap);

    // 初始化内核物理池和用户物理地址池的锁
    lock_init(&kernel_pool.lock);
    lock_init(&user_pool.lock);

    // 下面初始化内核虚拟地址的位图, 按实际物理内存大小生成数组
    kernel_vaddr.vaddr_bitmap.btmp_bytes_len = kbm_length;
    // 用于维护内核堆的虚拟地址, 所以要和内核内存池大小一致

    // 位图的数组指向一块没用的内存, 目前定位在内核内存池和用户内存池de 位图之外
    kernel_vaddr.vaddr_bitmap.bits = (void*) (MEM_BITMAP_BASE + kbm_length + ubm_length);

    kernel_vaddr.vaddr_start = K_HEAP_START;
    bitmap_init(&kernel_vaddr.vaddr_bitmap);

    put_str("    mem_pool_init done \n");
}



// 内存管理部分初始化入口
void mem_init() {
    put_str("mem_init start\n");
    uint32_t mem_bytes_total = (*(uint32_t*) (0xb00));  // 获取物理内存大小
    mem_pool_init(mem_bytes_total);                     // 初始化内存池
    // 初始化 mem_block_desc 数组 descs, 为 malloc 做准备
    block_desc_init(k_block_descs);
    put_str("mem_init done\n");
}

