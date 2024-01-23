%include "boot.inc"
SECTION MBR vstart=0x7c00 ;起始地址编译在0x7c00
    mov ax,cs
    mov ds,ax
    mov es,ax
    mov ss,ax
    mov fs,ax
    mov sp,0x7c00
    mov ax,0xb800 ; ax为文本信号起始区
    mov gs,ax     ; gs = ax 充当段基址的作用


    ;ah = 0x06 al = 0x00 想要调用int 0x06的BIOS提供的中断对应的函数 即向上移动即完成清屏功能
    ;cx dx 分别存储左上角与右下角的左边 详情看int 0x06函数调用
    mov ax,0x600 
    mov bx,0x700
    mov cx,0
    mov dx,0x184f
    
    ;调用BIOS中断
    int 0x10 

    ;新增功能 直接操作显存部分
    ;预设输出LOVE6 OS
    
    mov byte [gs:0x00],'L' ;低位字节储存ascii字符 小端储存内存顺序相反
    mov byte [gs:0x01],0xA4    ;背景储存在第二个字节 含字符与背景属性
    
    mov byte [gs:0x02],'O' 
    mov byte [gs:0x03],0xA4
    
    mov byte [gs:0x04],'V' 
    mov byte [gs:0x05],0xA4
    
    mov byte [gs:0x06],'E' 
    mov byte [gs:0x07],0xA4
    
    mov byte [gs:0x08],'Z' 
    mov byte [gs:0x09],0xA4
    
    mov byte [gs:0x0A],' ' 
    mov byte [gs:0x0B],0xA4
    
    mov byte [gs:0x0C],'O' 
    mov byte [gs:0x0D],0xA4
    
    mov byte [gs:0x0E],'S' 
    mov byte [gs:0x0F],0xA4

    		
    mov eax, LOADER_START_SECTOR
    mov bx, LOADER_BASE_ADDR ;loader放在第三个扇区，mbr在第一个扇区，第二个扇区空的。
    mov cx, 4
    call rd_disk_m_16

    jmp LOADER_BASE_ADDR + 0x300

;--------------
;读取磁盘n个扇区
rd_disk_m_16:
;--------------
	mov esi, eax;备份eax
	mov di, cx; 备份cx
;1 设置要读取的扇区数
	mov dx, 0x1f2 ;sector count端口号
	mov al, cl
	out dx, al

	mov eax, esi

;2 将LBA地址写入寄存器
	mov dx, 0x1f3
	out dx, al
	
	mov cl, 8
	mov dx, 0x1f4
	shr eax, cl
	out dx, al

	shr eax, cl
	mov dx, 0x1f5
	out dx, al

	shr eax, cl
	and al, 0x0f ;设置lba的最后四位
	or  al, 0xe0 ;设置为1110，表示lba模式，和两个固定位置1
	mov dx, 0x1f6
	out dx, al
;第三步，写入读命令
	mov dx, 0x1f7
	mov al, 0x20
	out dx, al

;第四步， 检测硬盘的状态
    .not_ready:
	nop
	in al, dx
	and al, 0x88 
	cmp al, 0x08
	jnz .not_ready

;第五步， 从端口读数据
	mov ax, di
	mov dx, 256
	mul dx  ;被乘数是ax或者al，16位乘法或者32位积，高16位在dx，低16位在ax
	mov cx, ax ;循环次数，一次两个字节，因为data寄存器16位。
	
	mov dx, 0x1f0
    .go_on_read:
	in ax, dx
	mov [bx], ax  ;段寄存器为0，平坦模式，所以bx最大地址为oxffff。bx已经被赋值0x900,所以loader被读取加载到0x900处
	add bx, 2
	loop .go_on_read
	ret
    
    ;预留两个字节 其余空余的全部用0填满 为使检测当前扇区最后两字节为0x55 0xaa 检测是否为有效扇区
    ;510 = 512字节-2预留字节  再减去（当前位置偏移量-段开始位置偏移量）求出来的是剩余空间
    times 510 - ($ - $$) db 0 
    db 0x55,0xaa

