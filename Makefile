# 这里的 obj-m 定义了最终生成的文件名 (ring0_exec.ko)
obj-m += ring0_exec.o

# KDIR 是内核源码路径，在 GitHub Actions 脚本中我们会动态指定它
all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean
