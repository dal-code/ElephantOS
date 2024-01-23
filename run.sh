#!/bin/bash/
nasm -I include/ -o boot/loader.bin boot/loader.S
dd if=/home/qing/bochs/boot/loader.bin of=/home/qing/bochs/hd60M.img bs=512 cou\
nt=4 seek=2 conv=notrunc

nasm -f elf -o lib/kernel/print.o lib/kernel/print.asm

gcc -m32 -I lib/kernel -c -o kernel/main.o kernel/main.c

ld -m elf_i386 -Ttext 0xc0001500 -e main -o kernel/kernel.bin kernel/main.o lib/kernel/print.o
dd if=/home/qing/bochs/kernel/kernel.bin of=/home/qing/bochs/hd60M.img bs=512 c\
ount=200 seek=9 conv=notrunc
bin/bochs -f bochsrc.disk




