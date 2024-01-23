#ifndef __LIB_USER_SYSCALL_H
#define __LIB_USER_SYSCALL_H

#include "stdint.h"

enum SYSCALL_NR { //存放调用子功能号
    SYS_GETPID,    //默认值为0，
    SYS_WRITE     //默认值为1，
};

uint32_t getpid(void);
uint32_t write(char* str);

#endif
