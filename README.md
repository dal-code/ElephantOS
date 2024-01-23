# ElephantOS
## 项目介绍
    根据真象还原一书实现一个小型的操作系统。
## 项目记录
+ 2024/01/23 完成内核的初始化，包括内存管理，中断管理，内核线程，用户进程。前十一章内容。
## 项目运行 
+ 环境配置
    + 1.安装Bochs，Bochs可以模拟硬件。
    + 2.配置Bochs，配置文件名为：bochsrc.disk。文件中设置从硬盘启动。
    + 3.使用bochs提供的bin/bximage创建硬盘 -hd命令 硬盘名称为hd60M.img
    + 4.启动bochs。bin/bochs -f bochsrc.disk
+ 运行
    + sh run.sh
    + c在终端显示
