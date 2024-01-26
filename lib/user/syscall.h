#ifndef __LIB_USER_SYSCALL_H
#define __LIB_USER_SYSCALL_H

#include "stdint.h"

enum SYSCALL_NR { //存放调用子功能号
    SYS_GETPID,    //默认值为0，
    SYS_WRITE,     //默认值为1，
    SYS_MALLOC,
    SYS_FREE
};

uint32_t getpid(void);
uint32_t write(int32_t fd, const void* buf, uint32_t count);
void* malloc(uint32_t size);
void free(void* ptr);

#endif
