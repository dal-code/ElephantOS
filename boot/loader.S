%include "boot.inc"

SECTION loader vstart=LOADER_BASE_ADDR   ;0x900
LOADER_STACK_TOP equ LOADER_BASE_ADDR   ; loader在保护模式下的栈指针地址，esp

;--------这个jmp注释调，将mbr中的jmp指令直接跳转到代码区，0x200
;jmp loader_start  ; 下面存放数据段 构建gdt 跳跃到下面的代码区   
			;这句可以不要，直接在mbr中可以jmp LOADER_BASE_ADDR + 0xb17 0xb17是loader_start的地址（不bao括jmp loader_start)


; 构建GDT及其内部描述符, 每个描述符8个字节, 拆分为高低各4字节(32位)
    GDT_BASE:   dd 0x00000000                       ; 第0个描述符,不可用
                dd 0x00000000

    CODE_DESC:  dd 0x0000ffff                       ; 低32位31~16位为段基址15~0位, 15~0位为段界限15~0位
                dd DESC_CODE_HIGH4

    DATA_STACK_DESC:    dd 0x0000ffff               ; 数据段(栈段)描述符
                        dd DESC_DATA_HIGH4

    VIDEO_DESC: dd 0x80000007                       ; 0xB8000 到0xBFFFF为文字模式显示内存 段界限:limit=(0xbffff-0xb8000) / 4k=0x7
                dd DESC_VIDEO_HIGH4                 ; 0xB

    GDT_SIZE:   equ $ - GDT_BASE                    ; 当前位置减去GDT_BASE的地址 等于GDT的大小
    GDT_LIMIT:  equ GDT_SIZE - 1                    ; SIZE - 1即为最大偏移量

    times 60 dq 0                                   ; 预留60个 四字型 描述符空位, 用于后续扩展 8字节
                                                    
    SELECTOR_CODE  equ (0x0001<<3) + TI_GDT + RPL0  ; 段选择子: 低3位为TI RPL状态, 其余为描述符索引值
    SELECTOR_DATA  equ (0x0002<<3) + TI_GDT + RPL0  
    SELECTOR_VIDEO equ (0x0003<<3) + TI_GDT + RPL0


    ; total_mem_bytes用于保存内存容量,以字节为单位,此位置比较好记。
    ; 当前偏移loader.bin文件头0x200字节,loader.bin的加载地址是0x900,-----从文件头到这里是0x200,宏定义不占字节，60*8+4*8= 512Byte, 
    ; 故total_mem_bytes内存中的地址是0xb00.将来在内核中咱们会引用此地址

    total_mem_bytes dd 0  ;dd为双字


    ;gdt指针, 前2字节(一个字)为gdt界限, 后4字节为gdt起始地址(共48位)
    gdt_ptr dw GDT_LIMIT        ;gdt放在文件头偏移量0   前边是低位
            dd GDT_BASE


    ;loadermsg db 'welcome to loader zone!'

    ;ards是地址范围描述符, 用于描述物理内存布局, 以便内核识别。一个20字节
    ; 人工对齐:total_mem_bytes 4字节 + gdt_ptr 6字节 + ards_buf 分配 244字节 + ards_nr 2字节 , 共256字节 0x100
    ards_buf times 244 db 0             ; 记录内存大小的缓冲区

    ards_nr dw 0                        ; 记录 ARDS（地址范围描述符） 结构体数量




loader_start:
	;---------------------------------------------------------
        ;INT 0x10       功能号:0x13     功能描述符:打印字符串
        ;---------------------------------------------------------
        ; 输入:
        ; AH 子功能号=13H
        ; BH = 页码
        ; BL = 属性（若AL=00H或01H）
        ; CX = 字符串长度
        ; (DH,DL)=坐标(行，列)
        ; ES:BP=字符串地址
        ; AL=显示输出方式
        ; 0——字符串中只含显示字符，其显示属性在BL中。显示后，光标位置不变
        ; 1——字符串中只含显示字符，其显示属性在BL中。显示后，光标位置改变
        ; 2——字符串中只含显示字符和显示属性。显示后，光标位置不变。
        ; 3——字符串中只含显示字符和显示属性。显示后，光标位置改变。
        ; 无返回值
	;-- 打印字符串
        ;mov sp, LOADER_BASE_ADDR
        ;mov bp, loadermsg           ; ES:BP 字符串地址, 在mbr es设置为了0, 现在在平坦模式下cs=es=0
        ;mov cx, 23                  ; 字符串长度
        ;mov ax, 0x1301              ; AH=13h，AL=01h
        ;mov bx, 0x001f              ; 页号为0（BH=0h），蓝底粉红字（BL=1fh）
        ;mov dx, 0x1800              ; (DH,DL)=坐标(行，列) (24,0), 意思是最后一行 0列开始
        ;int 0x10                    ; int 10 BIOS中断

;----------------------------BIOS中断获取硬件的内存大小的三种方法----------------------------
	; -------  int 15h eax = 0000E820h ,edx = 534D4150h ('SMAP') 获取内存布局  -------
        xor ebx, ebx                    ; 第一次调用将eb置0
        mov edx, 0x534d4150             ; edx只赋值一次，循环体中不会改变
        mov di,  ards_buf               ; di指向ARDS缓冲区

        .e820_mem_get_loop:             ; 循环获取每个ARDS内存范围描述结构
            mov eax, 0x0000e820         ; 执行int 0x15后,eax值变为0x534d4150, 所以每次执行int前都要更新为子功能号
            mov ecx, 20                 ; ARDS地址范围描述符结构大小是20字节
            int 0x15
            jc  .e820_failed_so_try_e801    ; 若cf位为1则有错误发生，尝试0xe801子功能
            add di, cx                  ; 使di增加20字节指向缓冲区中新的ARDS结构位置
            inc word [ards_nr]          ; ARDS数量加1
            cmp ebx, 0                  ; 若 ebx 为 0 且 cf 不为 1, 这说明 ards 全部返回，当前已是最后一个
            jnz .e820_mem_get_loop      ; 不为0则循环获取

            ; 在所有ards结构中，找出(base_add_low + length_low)的最大值，即内存的容量
            mov cx, [ards_nr]           ; 遍历每一个ARDS结构体,循环次数是ARDS的数量
            mov ebx, ards_buf
            xor edx, edx                ; 用edx记录最大值, 在这里先清零

        .find_max_mem_area:             ; 无须判断type是否为1,最大的内存块一定是可被使用
            mov eax, [ebx]              ; base_add_low
            add eax, [ebx+8]            ; base_add_low + length_low = 这块ADRS容量
            add ebx, 20                 ; 指向下一块ARDS
            cmp edx, eax                ; 找出最大,edx寄存器始终是最大的内存容量
            jge .next_ards              ; 如果edx>=eax, 继续遍历下一块
            mov edx, eax                ; 如果edx<=eax, 更新edx
        .next_ards:
            loop .find_max_mem_area
            jmp .mem_get_ok             ; 获取内存容量结束


 	; ------  int 15h ax = E801h 获取内存大小,最大支持4G  ------
        ; 返回后, ax cx 值一样,以KB为单位,bx dx值一样,以64KB为单位
        ; 在ax和cx寄存器中为低16M,在bx和dx寄存器中为16MB到4G
        .e820_failed_so_try_e801:
            mov ax, 0xe801
            int 15
            jc .e801_failed_so_try88    ; 若当前e801方法失败,就尝试0x88方法

            ; 1 先算出低15M的内存, ax和cx中是以KB为单位的内存数量,将其转换为以byte为单位
            ; 乘数在eax, 即内存数量, 积高16位在edx, 低16位在eax
            mov cx, 0x400               ; 0x400 = 1024
            mul cx
            shl edx, 16                 ; 左移16位, 将低16位放到edx高16位
            and eax, 0x0000FFFF         ; 0x0000FFFF = 1111 1111 1111 1111, 高16位置0
            or  edx, eax                ; 获得完整的32位积
            add edx, 0x100000           ; edx比实际少1M, 故要加1MB
            mov esi, edx                ; 先把低15MB的内存容量存入esi寄存器备份

            ; 2 再将16MB以上的内存转换为byte为单位,寄存器bx和dx中是以64KB为单位的内存数量
            xor eax, eax
            mov ax, bx
            mov ecx, 0x10000            ; 0x10000十进制为64KB
            mul ecx                     ; 32位乘法,默认的被乘数是eax, 积为64位, 高32位存入edx, 低32位存入eax
            add esi, eax                ; 由于此方法只能测出4G以内的内存, 故32位eax足够了, edx肯定为0, 只加eax便可
            mov edx, esi                ; edx为总内存大小
            jmp .mem_get_ok


        ; -----------------  int 15h ah = 0x88 获取内存大小,只能获取64M之内  ----------
        .e801_failed_so_try88:
            ; int 15后，ax存入的是以kb为单位的内存容量
            mov  ah, 0x88
            int  0x15
            jc   .error_hlt
            and  eax, 0x0000FFFF

            ; 16位乘法，被乘数是ax,积为32位, 积的高16位在dx中，积的低16位在ax中
            mov cx, 0x400               ; 0x400等于1024, 将ax中的内存容量换为以byte为单位
            mul cx
            shl edx, 16
            or  edx, eax                ; 把积的低16位组合到edx,为32位的积
            add edx, 0x100000           ; 0x88子功能只会返回1MB以上的内存, 故实际内存大小要加上1MB


        .mem_get_ok:
            mov [total_mem_bytes], edx  ; 将内存换为byte单位后存入total_mem_bytes处




; --------------------------------- 设置进入保护模式 -----------------------------
        ; 1 打开A20 gate
        ; 2 加载gdt
        ; 3 将cr0 的 pe位(第0位)置1

        ; -----------------  打开A20  ----------------
        in al, 0x92                 ; 端口号0x92 中的第1位变成 1 即可
        or al, 0000_0010B
        out 0x92, al

        ; -----------------  加载GDT  ----------------
        lgdt [gdt_ptr]

        ; -----------------  cr0第0位置1  ----------------
        mov eax, cr0
        or eax, 0x00000001
        mov cr0, eax
	; -------------------------------- 已经打开保护模式 ---------------------------------------
	jmp dword SELECTOR_CODE:p_mode_start        ; 刷新流水线

	.error_hlt:                     ; 出错则挂起
            hlt                         ; 处理器暂停, 直到出现中断或复位信号才继续



	[bits 32]
	p_mode_start: 

	    mov ax, SELECTOR_DATA
	    mov ds, ax
	    mov es, ax
	    mov ss, ax
	    mov esp, LOADER_STACK_TOP
	    mov ax, SELECTOR_VIDEO
	    mov gs, ax

	    ;mov byte [gs:160], 'P'

;------------加载 kernel-----------------------------------------------------
	mov eax, KERNEL_START_SECTOR            ; kernel.bin所在的扇区号
	mov ebx, KERNEL_BIN_BASE_ADDR           ; 从硬盘读出后写入的地址
	mov ecx, 200                            ; 读入的扇区数

	call rd_disk_m_32                       ; 从硬盘读取文件到内存, 上面eax, ebx, ecx是参数

; ----------------------------------创建页目录及页表并初始化页内存位图------------------------------------
    call setup_page

    ; gdt需要放在内核里
    ; 将描述符表地址&偏移量写入内存gdt_ptr，一会用新的地址加载
    sgdt [gdt_ptr]                          ; 取出GDT地址和偏移信息，存放在gdt_ptr这个内存位置上

    ; 视频段需要放在内核里与用户进程进行共享
    ; 将gdt描述符中视频段的段基址 + 0xc0000000
    mov ebx, [gdt_ptr + 2]                  ; 这里gdt_ptr前2字节是偏移量，后4字节是GDT基址，先选中GDT  加两个字节得到基址
    or dword [ebx + 0x18 + 4], 0xc0000000   ; 一个描述符8字节，0x18处是第3个段描述符也就是视频段, 修改段基址最高位为C, +4进入高4字节, 用or修改即可

    ; 将gdt的基址加上 0xc0000000 成为内核所在的地址
    add dword [gdt_ptr + 2], 0xc0000000
    add esp, 0xc0000000                     ; 将栈指针同样map到内核地址

    ; 页目录地址赋值给cr3
    mov eax, PAGE_DIR_TABLE_POS ;宏定义为0x100000
    mov cr3, eax

    ; 打开 cr0 的 pg位 (第31位)
    mov eax, cr0
    or  eax, 0x80000000
    mov cr0, eax

    ; 开启分页后, 用 gdt 新的地址重新加载
    lgdt [gdt_ptr]


;;;;;;;;;;;;;;;;;;;;;;;;;;;;  此时不刷新流水线也没问题  ;;;;;;;;;;;;;;;;;;;;;;;;
    ; 由于一直处在32位下,原则上不需要强制刷新, 经过实际测试没有以下这两句也没问题.
    ; 但以防万一, 还是加上啦, 免得将来出来莫句奇妙的问题.
    jmp SELECTOR_CODE:enter_kernel          ; 强制刷新流水线，更新 gdt 


    enter_kernel:                           ; 进入内核
        call kernel_init
        mov esp, 0xc009f000                 ; 给栈选个高地址且不影响内存其他位置的地方
        jmp KERNEL_ENTRY_POINT


    ; 重新初始化gs寄存器
    ;mov ax, SELECTOR_VIDEO
    ;mov gs,  ax
    ;mov byte [gs:160], 'V'


    ;jmp $


;----------------------------------------被调函数-------------------------------------------

   ;-----------------   将kernel.bin中的segment拷贝到编译的地址   -----------
    ; 此时，kernel.bin 已经被读取到内存 KERNEL_BIN_BASE_ADDR 位置上了
    kernel_init:
        xor eax, eax                                ; 清空通用寄存器
        xor ebx, ebx                                ; ebx 记录程序头表地址，即e_phoff
        xor ecx, ecx                                ; cx  记录程序头表中的 program header 数量
        xor edx, edx                                ; dx  记录 program header 尺寸, 即 e_phentsize
        
        mov dx, [KERNEL_BIN_BASE_ADDR + 42]         ; 偏移文件 42 字节处是 e_phentsize, 表示 program header 大小
        mov ebx, [KERNEL_BIN_BASE_ADDR + 28]        ; 偏移文件 28 字节处是 e_phoff, 表示程序头表在文件的偏移量

        add ebx, KERNEL_BIN_BASE_ADDR               ; 获取程序头表的地址(基地址 + 偏移量)
        mov cx,  [KERNEL_BIN_BASE_ADDR + 44]        ; 偏移文件 44 字节处是 e_phnum，表示程序头的数量

        .each_segment:
            cmp byte [ebx + 0], PT_NULL             ; 程序头表的第一个成员，p_type,若相等，则表示程序头没使用
            je  .PTNULL

            ; 为mem_cpy压入参数（从右往左）类似 memcpy(dst, src, size)
            ; 参数 size：待复制的大小
            push dword [ebx + 16]                   ; 偏移程序头 16 字节处是 p_filesz, 即本段在文件内的大小

            ; 参数 src: 源地址
            mov eax, [ebx + 4]                      ; 偏移程序头 4  字节处是 p_offset, 即本段在文件内的偏移大小
            add eax, KERNEL_BIN_BASE_ADDR           ; 加上基地址 = 物理地址
            push eax

            ; 参数 dst: 目的地址
            push dword [ebx + 8]                    ; 偏移程序头 8 字节处是 p_vaddr, 即本段在内存中的虚拟地址

            call .mem_cpy
            add esp, 12                             ; 清理栈中压入的三个参数


        .PTNULL:
            add ebx, edx                            ; 程序头的地址 + 程序头的大小 = 下一个程序头的地址
            loop .each_segment                      ; 复制下一个程序头
        
        ret


;----------  逐字节拷贝 mem_cpy(dst,src,size) ------------
; 输入:栈中三个参数(dst,src,size)
; 输出:无
;---------------------------------------------------------
    .mem_cpy:
        cld                                         ; 控制进行字符串操作时esi和edi的递增方式, cld增大, sld减小
        push ebp    
        mov ebp, esp
        push ecx                                    ; rep指令用到了ecx，外层指令也用到了ecx，所以备份

        ; 分析一下为什么是 8, 因为push了ebp, 所以相对应的都需要+4
        ; 并且进入函数时还 push了函数返回地址, 所以再+4, 所以一共+8
        mov edi, [ebp + 8]                          ; dst
        mov esi, [ebp + 12]                         ; src
        mov ecx, [ebp + 16]                         ; size
        rep movsb                                   ; 逐字节拷贝

        ; 恢复环境
        pop ecx
        pop ebp

        ret


; -------------   创建页目录及页表   ---------------
    setup_page:

        ; 先把页目录所占空间清 0
        mov ecx, 4096                               ; 1024 * 4 = 4096  
        mov esi, 0

        .clear_page_dir:    ;从0x100000
            mov byte [PAGE_DIR_TABLE_POS + esi], 0
            inc esi
            loop .clear_page_dir

        ; 开始创建页目录项（Page Directory Entry)
        .create_pde:
            mov eax, PAGE_DIR_TABLE_POS
            add eax, 0x1000                         ; 第一个页表的位置（仅次于页目录表，页目录表大小4KB）
            mov ebx, eax                            ; 0x00101 000, 储存到ebx为创建PTE时使用

            ; 下面将页目录项0和OxcOO都存为第一个页表的地址 ，每个页表表示4MB内存
            ; 这样Oxc03fffff(3G-3G04M)以下的地址和Ox003fffff(0-4M)以下的地址都 指向相同的页表
            ; 这是为将地址映射为内核地址做准备
            or eax,  PG_US_U | PG_RW_W | PG_P       ; 用户特权级，可读可写，存在内存
            mov [PAGE_DIR_TABLE_POS + 0x0], eax     ; 第一个目录项，0x00101 007
            mov [PAGE_DIR_TABLE_POS + 0xc00], eax   ; 第0xc00高10位0x300=768个页表占用的目录项，0xc00以上属于kernel空间
            ; 这里是把第768个目录页和第1个目录页指向同一个页表的物理地址：0x101000   
            ; 系统实际位于0～0x100000内存地址中，将系统虚拟地址0xc00000000映射到这低1M的空间内，只需要让0xc0000000的地址指向和低1M相同的页表即可

            sub eax, 0x1000
            mov [PAGE_DIR_TABLE_POS + 4092], eax    ; 使最后一个目录项指向页目录表自己的位置, 4092 = 1023 * 4

        
        ; 创建页表项（Page Table Entry）
        mov ecx, 256                                ; 1M低端内存/每页大小4K = 256
        mov esi, 0
        mov edx, PG_US_U | PG_RW_W | PG_P           ; edx中地址为0x0，属性为7，即111b

        .create_pte:
            mov  [ebx + esi * 4], edx               ; ebx = 0x00101 000, 即第一个PTE起始地址, 每个PTE = 4 byte
            add  edx, 4096                          ; edx + 4KB
            inc  esi
            loop .create_pte                        ; 低端1M内存中，物理地址=虚拟地址，这里创建了1M空间的页表项


        ; 创建内核其他页表的PDE
        mov eax, PAGE_DIR_TABLE_POS
        add eax, 0x2000                             ; eax指向第二个页表(每个页表对应一个PDE, 含有1024个页表项)
        or  eax, PG_US_U | PG_RW_W | PG_P
        mov ebx, PAGE_DIR_TABLE_POS                 
        mov ecx, 254                                ; 769~1022的所有目录项数量, 1022 - 769 + 1 = 254  1023要指向页目录表自身
        mov esi, 769                                

        .create_kernel_pde:
            mov  [ebx + esi * 4], eax
            inc  esi
            add  eax, 0x1000                        ; eax指向下一个页表
            loop .create_kernel_pde

        ret


;-------------------------------------------------------------------------------
	; 功能:读取硬盘n个扇区
        ; eax=LBA扇区号
	; ebx=将数据写入的内存地址
	; ecx=读入的扇区数   
;-------------------------------------------------------------------------------
	rd_disk_m_32:
        mov esi ,eax    ; 备份eax
        mov di ,cx      ; 备份cx

        ; 读写硬盘
        ; 1---设置要读取的扇区数
        mov dx ,0x1f2   ; 设置端口号，dx用来存储端口号的，要写入待读入的扇区数量
        mov al ,cl 
        out dx ,al      ; 读取的扇区数

        mov eax ,esi    ; 恢复eax


        ; 2---将LBA地址存入0x1f3～0x1f6
        ; LBA 7～0位写入端口0x1f3
        mov dx ,0x1f3
        out dx ,al 

        ; LBA 15~8位写入端口0x1f4
        mov cl ,8
        shr eax ,cl     ; 逻辑右移8位,将eax的最低8位移掉，让最低8位al的值变成接下来8位
        mov dx ,0x1f4
        out dx ,al 

        ; LBA 24～16位写入端口0x1f5
        shr eax ,cl 
        mov dx ,0x1f5
        out dx ,al 

        shr eax ,cl 
        and al ,0x0f    ; 设置lba 24～27位
        or al ,0xe0     ; 设置7～4位是1110表示LBA模式
        mov dx ,0x1f6
        out dx ,al 

        ; 3---向0x1f7端口写入读命令0x20
        mov dx ,0x1f7
        mov al ,0x20
        out dx ,al

        ; 4---检测硬盘状态
        .not_ready:
            ; 同写入命令端口，读取时标示硬盘状态，写入时是命令
            nop
            in al ,dx
            and al ,0x88    ; 第三位为1表示已经准备好了，第7位为1表示硬盘忙
            cmp al ,0x08
            jnz .not_ready

        ; 5---0x1f0端口读取数据
        mov ax ,di      ; 要读取的扇区数
        mov dx ,256     ; 一个扇区512字节，一次读取2字节，需要读取256次
        mul dx          ; 结果放在ax里
        mov cx ,ax      ; 要读取的次数

        mov dx ,0x1f0

        .go_on_read:
            in ax, dx
            mov [ebx], ax    ; bx是要读取到的内存地址
            add ebx, 0x02
            loop .go_on_read        ; 循环cx次

        ret


; %include "boot.inc"
; SECTION loader vstart=LOADER_BASE_ADDR
; LOADER_STACK_TOP equ LOADER_BASE_ADDR 		   ;是个程序都需要有栈区 我设置的0x600以下的区域到0x500区域都是可用空间 况且也用不到
; jmp loader_start                     		   	   ;下面存放数据段 构建gdt 跳跃到下面的代码区 
; 				       		   ;对汇编再复习 db define byte,dw define word,dd define dword
;     GDT_BASE        : dd 0x00000000          		   ;刚开始的段选择子0不能使用 故用两个双字 来填充
;    		       dd 0x00000000 
    
;     CODE_DESC       : dd 0x0000FFFF         		   ;FFFF是与其他的几部分相连接 形成0XFFFFF段界限
;     		       dd DESC_CODE_HIGH4
    
;     DATA_STACK_DESC : dd 0x0000FFFF
;   		       dd DESC_DATA_HIGH4
    		       
;     VIDEO_DESC      : dd 0x80000007         		   ;0xB8000 到0xBFFFF为文字模式显示内存 B只能在boot.inc中出现定义了 此处不够空间了 8000刚好够
;                       dd DESC_VIDEO_HIGH4     	   ;0x0007 (bFFFF-b8000)/4k = 0x7
                 
;     GDT_SIZE              equ $ - GDT_BASE               ;当前位置减去GDT_BASE的地址 等于GDT的大小
;     GDT_LIMIT       	   equ GDT_SIZE - 1   	           ;SIZE - 1即为最大偏移量
    
;     times 59 dq 0                             	   ;预留59个 define double四字型 8字描述符
;     times 5 db 0                                         ;为了凑整数 0x800 导致前面少了三个
    
;     total_mem_bytes  dd 0
;     	               			           ;在此前经过计算程序内偏移量为0x200 我算了算 60*8+4*8=512 刚好是 0x200 说这里的之后还会用到
;     							   ;我们刚开始程序设置的地址位置为 0x600 那这就是0x800
 
    
;     gdt_ptr           dw GDT_LIMIT			   ;gdt指针 2字gdt界限放在前面 4字gdt地址放在后面 lgdt 48位格式 低位16位界限 高位32位起始地址
;     		       dd GDT_BASE
    		       
;     ards_buf times 244 db 0                              ;buf  记录内存大小的缓冲区
;     ards_nr dw 0					   ;nr 记录20字节结构体个数  计算了一下 4+2+4+244+2=256 刚好256字节
;     							   ;书籍作者有强迫症 哈哈 这里244的buf用不到那么多的 实属强迫症使然 哈哈
    
;     SELECTOR_CODE        equ (0X0001<<3) + TI_GDT + RPL0    ;16位寄存器 4位TI RPL状态 GDT剩下的选择子
;     SELECTOR_DATA	  equ (0X0002<<3) + TI_GDT + RPL0
;     SELECTOR_VIDEO       equ (0X0003<<3) + TI_GDT + RPL0   
    
; loader_start:
    
;     mov sp,LOADER_BASE_ADDR                                   ;先初始化了栈指针
;     xor ebx,ebx                                               ;异或自己 即等于0
;     mov ax,0                                       
;     mov es,ax                                                 ;心有不安 还是把es给初始化一下
;     mov di,ards_buf                                           ;di指向缓冲区位置
; .e820_mem_get_loop:
;     mov eax,0x0000E820                                            ;每次都需要初始化
;     mov ecx,0x14
;     mov edx,0x534d4150
    
;     int 0x15                                                  ;调用了0x15中断
;     jc  .e820_failed_so_try_e801                              ;这时候回去看了看jc跳转条件 就是CF位=1 carry flag = 1 中途失败了即跳转
;     add di,cx							;把di的数值增加20 为了下一次作准备
;     inc word [ards_nr]
;     cmp ebx,0
;     jne .e820_mem_get_loop                                    ;直至读取完全结束 则进入下面的处理时间
    
;     mov cx,[ards_nr]                                          ;反正也就是5 cx足以
;     mov ebx,ards_buf
;     xor edx,edx
; .find_max_mem_area:
    
;     mov eax,[ebx]						 ;我也不是很清楚为什么用内存上限来表示操作系统可用部分
;     add eax,[ebx+8]                                            ;既然作者这样用了 我们就这样用
;     add ebx,20    						 ;简单的排序
;     cmp edx,eax
;     jge .next_ards
;     mov edx,eax

; .next_ards:
;     loop .find_max_mem_area
;     jmp .mem_get_ok
    
; .e820_failed_so_try_e801:                                       ;地址段名字取的真的简单易懂 哈哈哈哈 
;     mov ax,0xe801
;     int 0x15
;     jc .e801_failed_so_try_88
   
; ;1 先算出来低15MB的内存    
;     mov cx,0x400
;     mul cx                                                      ;低位放在ax 高位放在了dx
;     shl edx,16                                                  ;dx把低位的16位以上的书往上面抬 变成正常的数
;     and eax,0x0000FFFF                                          ;把除了16位以下的 16位以上的数清零 防止影响
;     or edx,eax                                                  ;15MB以下的数 暂时放到了edx中
;     add edx,0x100000                                            ;加了1MB 内存空缺 
;     mov esi,edx
    
; ;2 接着算16MB以上的内存 字节为单位
;     xor eax,eax
;     mov ax,bx
;     mov ecx,0x10000                                              ;0x10000为64KB  64*1024  
;     mul ecx                                                      ;高32位为0 因为低32位即有4GB 故只用加eax
;     mov edx,esi
;     add edx,eax
;     jmp .mem_get_ok
 
; .e801_failed_so_try_88:
;      mov ah,0x88
;      int 0x15
;      jc .error_hlt
;      and eax,0x0000FFFF
;      mov cx,0x400                                                 ;1024
;      mul cx
;      shl edx,16
;      or edx,eax 
;      add edx,0x100000

; .error_hlt:
;      jmp $
; .mem_get_ok:
;      mov [total_mem_bytes],edx
; ; --------------------------------- 设置进入保护模式 -----------------------------
; ; 1 打开A20 gate
; ; 2 加载gdt
; ; 3 将cr0 的 pe位置1
    
;     in al,0x92                 ;端口号0x92 中 第1位变成1即可
;     or al,0000_0010b
;     out 0x92,al
   
    
;     lgdt [gdt_ptr]
    
    
;     mov eax,cr0                ;cr0寄存器第0位设置位1
;     or  eax,0x00000001              
;     mov cr0,eax
      
; ;-------------------------------- 已经打开保护模式 ---------------------------------------
;     jmp dword SELECTOR_CODE:p_mode_start                       ;刷新流水线
 
; [bits 32]
; p_mode_start: 
;     mov ax,SELECTOR_DATA
;     mov ds,ax
;     mov es,ax
;     mov ss,ax
;     mov esp,LOADER_STACK_TOP
    
; ;------------------------------- 加载内核到缓冲区 -------------------------------------------------

;     mov eax, KERNEL_START_SECTOR
;     mov ebx, KERNEL_BIN_BASE_ADDR  
    
;     mov ecx,200
;     call rd_disk_m_32

; ;------------------------------- 启动分页 ---------------------------------------------------
    
;     call setup_page
;     							         ;这里我再把gdtr的格式写一下 0-15位界限 16-47位起始地址
;     sgdt [gdt_ptr]                                             ;将gdt寄存器中的指 还是放到gdt_ptr内存中 我们修改相对应的 段描述符
;     mov ebx,[gdt_ptr+2]                                        ;32位内存先倒出来 为的就是先把显存区域描述法的值改了 可以点开boot.inc 和 翻翻之前的段描述符
;                                                                ;段基址的最高位在高4字节 故
;     or dword [ebx+0x18+4],0xc0000000
;     add dword [gdt_ptr+2],0xc0000000                            ;gdt起始地址增加 分页机制开启的前奏
    
;     add esp,0xc0000000                                         ;栈指针也进入高1GB虚拟内存区
    
;     mov eax,PAGE_DIR_TABLE_POS
;     mov cr3,eax
    
;     mov eax,cr0
;     or eax,0x80000000
;     mov cr0,eax
    
;     lgdt [gdt_ptr]
    
;     mov eax,SELECTOR_VIDEO
;     mov gs,eax
;     mov byte [gs:160],'V'
    
;     jmp SELECTOR_CODE:enter_kernel
    
; ;------------------------------ 跳转到内核区    

; enter_kernel:
;     call kernel_init					          ;根据我们的1M以下的内存分布区 综合考虑出的数据
;     mov  esp,0xc009f000
;     jmp  KERNEL_ENTRY_POINT

; ;------------------------------- 创建页表 ------------------------------------------------    
; setup_page:
;     mov ecx,0x1000                                             ;循环4096次 将页目录项清空 内存清0
;     mov esi,0                                                   
;  .clear_page_dir_mem:                                          ;dir directory 把页目录项清空
;     mov byte [PAGE_DIR_TABLE_POS+esi],0
;     inc esi
;     loop .clear_page_dir_mem
    
;  .create_pde: 
;     mov eax,PAGE_DIR_TABLE_POS				  ;页目录项 起始位置
;     add eax,0x1000                                              ;页目录项刚好4k字节 add eax即得第一个页表项的地址
;                                                                 ;接下来我们要做的是 把虚拟地址1M下和3G+1M 两部分的1M内存在页目录项中都映射到物理地址0-0XFFFFF
;     or  eax, PG_P | PG_RW_W | PG_US_U                           ;哦 悟了 哈哈哈 这里设置为PG_US_U 是因为init在用户进程 如果这里设置成US_S 这样子连进内核都进不去了
     
;     mov [PAGE_DIR_TABLE_POS+0x0],eax                             ;页目录项偏移0字节与偏移0xc00 对应0x 一条页目录项对应2^22位4MB 偏移由前10位*4字节得到 可自己推算一下
;     mov [PAGE_DIR_TABLE_POS+0xc00],eax                        
;     sub eax,0x1000      
    
;     mov [PAGE_DIR_TABLE_POS+4092],eax                           ;虚拟内存最后一个目录项 指向页目录表自身 书上写的是为了动态操纵页表 我也不是很清楚 反正有用 先放放

; ;这里就创建了一页页表    
;     mov eax,PAGE_DIR_TABLE_POS
;     add eax,0x1000
;     mov ecx,256
;     mov esi,0
;     mov ebx,PG_P | PG_RW_W | PG_US_U 
    
;  .create_kernel_pte:           
;     mov [eax+esi*4],ebx
;     inc esi
;     add ebx,0x1000
;     loop .create_kernel_pte 
    
    
; ;这里对于我们这里填写的目录项所对应的页表 页表中我们还没填写的值
; ;为了实现 真正意义上的 内核空间被用户进程完全共享
; ;只是把页目录与页表的映射做出来了 

;     mov eax,PAGE_DIR_TABLE_POS
;     add eax,0x2000       					   ;eax此时处于第二个页表
;     or  eax,PG_P | PG_RW_W | PG_US_U
; ;这里循环254次可以来分析一下 我们这里做的是 0xc0 以上部分的映射    0xc0 对应的是第768个页表项 页表项中一共有 2^10=1024项
; ;第1023项我们已经设置成 映射到页目录项本身位置了 即1022 - 769 +1 = 254
;     mov ebx,PAGE_DIR_TABLE_POS
;     mov ecx,254						  
;     mov esi,769
        
;  .create_kernel_pde:
;     mov [ebx+esi*4],eax
;     inc esi
;     add eax,0x1000
;     loop .create_kernel_pde 
    
;     ret            
    
; ;----------------------- 初始化内核 把缓冲区的内核代码放到0x1500区域 ------------------------------------------
; ;这个地方主要对elf文件头部分用的很多
; ;可以参照着书上给的格式 来比较对比
; kernel_init:
;     xor eax,eax   ;全部清零
;     xor ebx,ebx
;     xor ecx,ecx
;     xor edx,edx
    
;     ;这里稍微解释一下 因为0x70000 为64kb*7=448kb 而我们的内核映射区域是4MB 而在虚拟地址4MB以内的都可以当作1:1映射
;     mov ebx,[KERNEL_BIN_BASE_ADDR+28]
;     add ebx,KERNEL_BIN_BASE_ADDR                               ;ebx当前位置为程序段表
;     mov dx,[KERNEL_BIN_BASE_ADDR+42]		         ;获取程序段表每个条目描述符字节大小
;     mov cx,[KERNEL_BIN_BASE_ADDR+44]                         ;一共有几个段
    
     
;  .get_each_segment:
;     cmp dword [ebx+0],PT_NULL
;     je .PTNULL                                                 ;空即跳转即可 不进行mem_cpy
    
;     mov eax,[ebx+8]
;     cmp eax,0xc0001500
;     jb .PTNULL
    
        
;     push dword [ebx+16]                                        ;ebx+16在存储的数是filesz  可以翻到Loader刚开始
                                                               
;     mov eax,[ebx+4]                                            
;     add eax,KERNEL_BIN_BASE_ADDR
;     push eax                                                   ;p_offset 在文件中的偏移位置    源位置         
;     push dword [ebx+8]                                         ;目标位置
     
;     call mem_cpy
;     add esp,12                                                 ;把三个参数把栈扔出去 等于恢复栈指针
    
;  .PTNULL:
;     add  ebx,edx                                               ;edx是一个描述符字节大小
;     loop .get_each_segment                                     ;继续进行外层循环    
;     ret
                                        
; mem_cpy:
;     cld                                                        ;向高地址自动加数字 cld std 向低地址自动移动
;     push ebp                                                   ;保存ebp 因为访问的时候通过ebp 良好的编程习惯保存相关寄存器
;     mov  ebp,esp 
;     push ecx                                                   ;外层循环还要用 必须保存 外层eax存储着还有几个段
    
;                                                                ;分析一下为什么是 8 因为进入的时候又重新push了ebp 所以相对应的都需要+4
;                                                                ;并且进入函数时 还Push了函数返回地址 所以就那么多了
;     mov edi,[ebp+8]                                            ;目的指针 edi存储的是目的位置 4+4
;     mov esi,[ebp+12]                                           ;源指针   源位置             8+4
;     mov ecx,[ebp+16]                                           ;与Movsb好兄弟 互相搭配      12+4
    
    
;     rep movsb                                                  ;一个一个字节复制
       
;     pop ecx 
;     pop ebp
;     ret
    
; ;------------------------ rd_disk_m_32  在mbr.S复制粘贴过来的 修改了点代码 ----------------------
; rd_disk_m_32:
; ;1 写入待操作磁盘数
; ;2 写入LBA 低24位寄存器 确认扇区
; ;3 device 寄存器 第4位主次盘 第6位LBA模式 改为1
; ;4 command 写指令
; ;5 读取status状态寄存器 判断是否完成工作
; ;6 完成工作 取出数据
 
;  ;;;;;;;;;;;;;;;;;;;;;
;  ;1 写入待操作磁盘数
;  ;;;;;;;;;;;;;;;;;;;;;
;     mov esi,eax   ; !!! 备份eax
;     mov di,cx     ; !!! 备份cx
    
;     mov dx,0x1F2  ; 0x1F2为Sector Count 端口号 送到dx寄存器中
;     mov al,cl     ; !!! 忘了只能由ax al传递数据
;     out dx,al     ; !!! 这里修改了 原out dx,cl
    
;     mov eax,esi   ; !!!袄无! 原来备份是这个用 前面需要ax来传递数据 麻了
    
; ;;;;;;;;;;;;;;;;;;;;;
; ;2 写入LBA 24位寄存器 确认扇区
; ;;;;;;;;;;;;;;;;;;;;;
;     mov cl,0x8    ; shr 右移8位 把24位给送到 LBA low mid high 寄存器中

;     mov dx,0x1F3  ; LBA low
;     out dx,al 
    
;     mov dx,0x1F4  ; LBA mid
;     shr eax,cl    ; eax为32位 ax为16位 eax的低位字节 右移8位即8~15
;     out dx,al
    
;     mov dx,0x1F5
;     shr eax,cl
;     out dx,al
    
; ;;;;;;;;;;;;;;;;;;;;;
; ;3 device 寄存器 第4位主次盘 第6位LBA模式 改为1
; ;;;;;;;;;;;;;;;;;;;;;

    		 
;     		  ; 24 25 26 27位 尽管我们知道ax只有2 但还是需要按规矩办事 
;     		  ; 把除了最后四位的其他位置设置成0
;     shr eax,cl
    
;     and al,0x0f 
;     or al,0xe0   ;!!! 把第四-七位设置成0111 转换为LBA模式
;     mov dx,0x1F6 ; 参照硬盘控制器端口表 Device 
;     out dx,al

; ;;;;;;;;;;;;;;;;;;;;;
; ;4 向Command写操作 Status和Command一个寄存器
; ;;;;;;;;;;;;;;;;;;;;;

;     mov dx,0x1F7 ; Status寄存器端口号
;     mov ax,0x20  ; 0x20是读命令
;     out dx,al
    
; ;;;;;;;;;;;;;;;;;;;;;
; ;5 向Status查看是否准备好惹 
; ;;;;;;;;;;;;;;;;;;;;;
    
; 		   ;设置不断读取重复 如果不为1则一直循环
;   .not_ready:     
;     nop           ; !!! 空跳转指令 在循环中达到延时目的
;     in al,dx      ; 把寄存器中的信息返还出来
;     and al,0x88   ; !!! 0100 0100 0x88
;     cmp al,0x08
;     jne .not_ready ; !!! jump not equal == 0
    
    
; ;;;;;;;;;;;;;;;;;;;;;
; ;6 读取数据
; ;;;;;;;;;;;;;;;;;;;;;

;     mov ax,di      ;把 di 储存的cx 取出来
;     mov dx,256
;     mul dx        ;与di 与 ax 做乘法 计算一共需要读多少次 方便作循环 低16位放ax 高16位放dx
;     mov cx,ax      ;loop 与 cx相匹配 cx-- 当cx == 0即跳出循环
;     mov dx,0x1F0
;  .go_read_loop:
;     in ax,dx      ;两字节dx 一次读两字
;     mov [ebx],ax
;     add ebx,2
;     loop .go_read_loop
;     ret ;与call 配对返回原来的位置 跳转到call下一条指令


	




