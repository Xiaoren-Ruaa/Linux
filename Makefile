obj-m += ksu_cmd.o

# KDIR 将在 GitHub Actions 中动态设置
KDIR ?= /lib/modules/$(shell uname -r)/build

all:
	make -C $(KDIR) M=$(PWD) modules

clean:
	make -C $(KDIR) M=$(PWD) clean