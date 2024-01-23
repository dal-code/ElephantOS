bin/bochs -f bochsrc.disk

mbr:
nasm -I boot/include/ -o boot/mbr.bin boot/mbr.S
dd if=/home/qing/bochs/boot/mbr.bin of=/home/qing/bochs/hd60M.img bs=512 count=1 conv=notrunc

loader:
nasm -I boot/include/ -o boot/loader.bin boot/loader.S
dd if=/home/qing/bochs/boot/loader.bin of=/home/qing/bochs/hd60M.img bs=512 count=4 seek=2 conv=notrunc

kernal:
gcc -m32 -c -o kernel/main.o kernel/main.c
ld -m elf_i386 kernel/main.o -Ttext 0xc0001500 -e main -o kernel/kernel.bin
dd if=/home/qing/bochs/kernel/kernel.bin of=/home/qing/bochs/hd60M.img bs=512 count=200 seek=9 conv=notrunc

 