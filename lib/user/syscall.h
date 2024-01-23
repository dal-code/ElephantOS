#ifndef __LIB_USER_SYSCALL_H
#define __LIB_USER_SYSCALL_H

#include "stdint.h"

enum SYSCALL_NR { //存放调用子功能号
    SYS_GETPID    //默认值为0，
};

uint32_t getpid(void);

#endif
