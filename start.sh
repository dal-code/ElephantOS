#!/bin/bash/
# MBR:
nasm -I boot/include/ -o boot/mbr.bin boot/mbr.S
# 写入磁盘
dd if=/home/qing/bochs/boot/mbr.bin of=/home/qing/bochs/hd60M.img bs=512 count=1 conv=notrunc
# Loader
nasm -I boot/include/ -o boot/loader.bin boot/loader.S
# 写入磁盘
dd if=/home/qing/bochs/boot/loader.bin of=/home/qing/bochs/hd60M.img bs=512 count=4 seek=2 conv=notrunc