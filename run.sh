#!/bin/bash/

# kernal 编译、链接，生成内核elf_i386文件，写入磁盘
make all 
# 启动
bin/bochs -f bochsrc.disk




