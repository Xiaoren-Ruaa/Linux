#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/kmod.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/workqueue.h>
#include <linux/slab.h>

#define PROC_NAME "ring0_cmd"
#define MAX_CMD_LEN 256

/* 1. 定义工作队列结构体，用于包装我们要执行的命令 */
struct cmd_work {
    struct work_struct work;
    char cmd[MAX_CMD_LEN];
};

/* 2. 核心异步执行逻辑 (在内核后台线程池中运行，绝不卡死主调度器) */
static void execute_cmd_work(struct work_struct *work) {
    // 从工作节点反向解析出我们的数据结构
    struct cmd_work *my_work = container_of(work, struct cmd_work, work);
    
    // 准备执行环境
    char *envp[] = { "HOME=/", "PATH=/sbin:/vendor/bin:/system/bin", NULL };
    char *argv[] = { "/system/bin/sh", "-c", my_work->cmd, NULL };
    int ret;

    printk(KERN_INFO "Ring0: Async execution triggered -> %s\n", my_work->cmd);
    
    // UMH_WAIT_EXEC：内核将进程交给调度器后立即返回，性能损耗降至最低
    ret = call_usermodehelper(argv[0], argv, envp, UMH_WAIT_EXEC);
    
    if (ret != 0) {
        printk(KERN_ERR "Ring0: Command failed with code: %d\n", ret);
    }

    // 执行完毕，释放堆内存，防止内存泄漏
    kfree(my_work);
}

/* 3. 拦截用户态写入 /proc/ring0_cmd 的数据 */
static ssize_t proc_write(struct file *file, const char __user *ubuf, size_t count, loff_t *ppos) {
    struct cmd_work *my_work;
    size_t len = count;

    if (len >= MAX_CMD_LEN) {
        len = MAX_CMD_LEN - 1;
    }

    // 动态分配内存 (GFP_KERNEL 允许休眠，适合当前上下文)
    my_work = kmalloc(sizeof(struct cmd_work), GFP_KERNEL);
    if (!my_work) {
        return -ENOMEM;
    }

    // 将用户态传递的命令安全拷贝到内核空间
    if (copy_from_user(my_work->cmd, ubuf, len)) {
        kfree(my_work);
        return -EFAULT;
    }

    my_work->cmd[len] = '\0';
    
    // 清理可能由于 echo 自带的换行符
    if (len > 0 && my_work->cmd[len-1] == '\n') {
        my_work->cmd[len-1] = '\0';
    }

    // 初始化任务节点并压入内核全局工作队列
    INIT_WORK(&my_work->work, execute_cmd_work);
    schedule_work(&my_work->work);

    // 立即向用户态返回成功，实现真正的非阻塞调用
    return count;
}

/* 4. Android 5.10 (Kernel 5.6+) 专用的 Procfs 操作结构体 */
static const struct proc_ops popops = {
    .proc_write = proc_write,
};

static struct proc_dir_entry *ent;

/* 5. 模块加载初始化 */
static int __init ring0_init(void) {
    // 创建一个只写 (0222) 的 proc 节点，防止普通 App 嗅探
    ent = proc_create(PROC_NAME, 0222, NULL, &popops);
    if (!ent) {
        printk(KERN_ERR "Ring0: Failed to create /proc/%s\n", PROC_NAME);
        return -ENOMEM;
    }
    printk(KERN_INFO "Ring0: High-Performance Engine Loaded. Hooked at /proc/%s\n", PROC_NAME);
    return 0;
}

/* 6. 模块卸载清理 */
static void __exit ring0_exit(void) {
    proc_remove(ent);
    printk(KERN_INFO "Ring0: Engine Unloaded.\n");
}

module_init(ring0_init);
module_exit(ring0_exit);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("High-Performance Async Ring0 Executor via Workqueue");
