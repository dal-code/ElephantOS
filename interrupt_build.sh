#!/bin/bash/ 
nasm -f elf -o build/print.o lib/kernel/print.asm 
nasm -f elf -o build/kernel.o kernel/kernel.asm 

gcc -m32 -I lib/kernel/ -c -o build/timer.o device/timer.c
gcc -m32 -I lib/kernel/ -m32 -I lib/ -m32 -I kernel/ -c -fno-builtin -o build/main.o kernel/main.c
gcc -m32 -I lib/kernel/ -m32 -I lib/ -m32 -I kernel/ -c -fno-builtin -o build/interrupt.o kernel/interrupt.c
gcc -m32 -I lib/kernel/ -m32 -I lib/ -m32 -I kernel/ -c -fno-builtin -o build/init.o kernel/init.c

ld -m elf_i386 -Ttext=0xc0001500 -e main -o build/kernel.bin build/main.o build/init.o build/interrupt.o build/print.o build/kernel.o build/timer.o

dd if=build/kernel.bin of=/home/qing/bochs/hd60M.img bs=512 c\
\
ount=200 seek=9 conv=notrunc
bin/bochs -f bochsrc.disk


