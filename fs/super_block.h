#ifndef __FS_SUPER_BLOCK_H
#define __FS_SUPER_BLOCK_H
#include "stdint.h"

/* 超级块 */
struct super_block {
   uint32_t magic;		         // 用来标识文件系统类型,支持多文件系统的操作系统通过此标志来识别文件系统类型
   uint32_t sec_cnt;		         // 本分区总共的扇区数
   uint32_t inode_cnt;		      // 本分区中inode数量
   uint32_t part_lba_base;	      // 本分区的起始lba地址

   uint32_t block_bitmap_lba;	      // 空闲块起始扇区地址
   uint32_t block_bitmap_sects;     // 空闲块位图大小

   uint32_t inode_bitmap_lba;	      // i结点位图起始扇区lba地址
   uint32_t inode_bitmap_sects;	   // i结点位图占用的扇区数量

   uint32_t inode_table_lba;	      // inode数组起始扇区lba地址
   uint32_t inode_table_sects;	   // inode数组占用的扇区数量

   uint32_t data_start_lba;	      // 数据区开始的第一个扇区号
   uint32_t root_inode_no;	         // 根目录地址，inode号
   uint32_t dir_entry_size;	      // 根目录中目录项的大小

   uint8_t  pad[460];		         // 加上460字节,凑够512字节1扇区大小
} __attribute__ ((packed));
#endif
