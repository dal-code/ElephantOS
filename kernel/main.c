// #include "debug.h"
// #include "string.h"
// #include "memory.h"
// #include "print.h"
// #include "init.h"
// #include "../thread/thread.h"
// #include "interrupt.h"
// #include "../device/console.h"

// void k_thread_a(void*);
// void k_thread_b(void*);
// void k_thread_c(void*);
// void k_thread_d(void*);
// int main(void) {
//    put_str("I am kernel\n");
//    init_all();

//    thread_start("k_thread_a", 31, k_thread_a, "argA ");
//    thread_start("k_thread_b", 8, k_thread_b, "argB ");
//    thread_start("k_thread_c", 31, k_thread_c, "argC ");
//    thread_start("k_thread_d", 8, k_thread_d, "argD ");
//    intr_enable();	// 打开中断,使时钟中断起作用
//    while(1) {
//       console_put_str("Main ");
//    };
//    return 0;
// }

// /* 在线程中运行的函数 */
// void k_thread_a(void* arg) {     
// /* 用void*来通用表示参数,被调用的函数知道自己需要什么类型的参数,自己转换再用 */
//    char* para = arg;
//    while(1) {
//       console_put_str(para);
//    }
// }

// /* 在线程中运行的函数 */
// void k_thread_b(void* arg) {     
// /* 用void*来通用表示参数,被调用的函数知道自己需要什么类型的参数,自己转换再用 */
//    char* para = arg;
//    while(1) {
//       console_put_str(para);
//    }
// }

// /* 在线程中运行的函数 */
// void k_thread_c(void* arg) {     
// /* 用void*来通用表示参数,被调用的函数知道自己需要什么类型的参数,自己转换再用 */
//    char* para = arg;
//    while(1) {
//       console_put_str(para);
//    }
// }


// /* 在线程中运行的函数 */
// void k_thread_d(void* arg) {     
// /* 用void*来通用表示参数,被调用的函数知道自己需要什么类型的参数,自己转换再用 */
//    char* para = arg;
//    while(1) {
//       console_put_str(para);
//    }
// }

#include "print.h"
#include "init.h"
#include "debug.h"
#include "string.h"
#include "memory.h"
#include "../thread/thread.h"
#include "interrupt.h"
#include "../device/console.h"
#include "../device/ioqueue.h"
#include "../device/keyboard.h"
#include "../userprog/process.h"

int a = 0,b = 0;
void test_thread1(void* arg);
void test_thread2(void* arg);
void u_prog_a(void);
void u_prog_b(void);

int main(void) {
   // put_str("I am kernel\n");
   init_all();
   thread_start("kernel_thread_a",31,test_thread1,"argA: ");
   // thread_start("kernel_thread_b",31,test_thread2,"argB: ");
   process_execute(u_prog_a,"user_prog_a");
   // process_execute(u_prog_b,"user_prog_b");
   intr_enable();
   
   while(1);
   return 0;
}

void test_thread1(void* arg)
{
    while(1)
    {
        console_put_str((char*)arg);
        console_put_int(a);
        console_put_char(' ');
    }
}

void test_thread2(void* arg)
{
    while(1)
    {
        console_put_str((char*)arg);
        console_put_int(b);
        console_put_char(' ');
    }
}

void u_prog_a(void)
{
    while(1)
    {
    	++a;
    }
}

void u_prog_b(void)
{
    while(1)
    {
    	++b;
    }
}
