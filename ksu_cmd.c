#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/string.h>
#include <linux/slab.h>
#include <linux/sched.h>
#include <linux/cred.h>
#include <linux/uidgid.h>
#include <linux/fs.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Your Name");
MODULE_DESCRIPTION("Execute any shell command from kernel space via /proc/ksu_cmd");

#define PROC_NAME "ksu_cmd"
#define CMD_BUF_SIZE 256

static struct proc_dir_entry *proc_entry;

// 只允许 root 用户写入
static bool allow_write(struct file *file) {
    kuid_t uid = current_uid();
    return uid_eq(uid, GLOBAL_ROOT_UID);
}

// 写入处理函数：接收命令并立即执行
static ssize_t cmd_write(struct file *file, const char __user *buffer,
                         size_t count, loff_t *pos) {
    char cmd_buf[CMD_BUF_SIZE];
    int ret;

    if (!allow_write(file))
        return -EPERM;

    if (count >= CMD_BUF_SIZE)
        count = CMD_BUF_SIZE - 1;

    if (copy_from_user(cmd_buf, buffer, count))
        return -EFAULT;
    cmd_buf[count] = '\0';

    // 去掉末尾换行
    if (cmd_buf[count-1] == '\n')
        cmd_buf[count-1] = '\0';

    printk(KERN_INFO "KSU_CMD: executing: %s\n", cmd_buf);

    char *argv[] = { "/system/bin/sh", "-c", cmd_buf, NULL };
    static char *envp[] = {
        "HOME=/",
        "PATH=/sbin:/system/bin:/system/xbin:/vendor/bin",
        NULL
    };

    ret = call_usermodehelper(argv[0], argv, envp, UMH_WAIT_PROC);
    if (ret != 0)
        printk(KERN_ERR "KSU_CMD: call_usermodehelper failed: %d\n", ret);
    else
        printk(KERN_INFO "KSU_CMD: command executed successfully\n");

    return count;
}

// 读取时返回帮助信息
static ssize_t cmd_read(struct file *file, char __user *buffer,
                        size_t count, loff_t *pos) {
    char msg[] = "Usage: echo 'command' > /proc/ksu_cmd\nOnly root can write.\n";
    if (*pos >= sizeof(msg))
        return 0;
    if (count > sizeof(msg) - *pos)
        count = sizeof(msg) - *pos;
    if (copy_to_user(buffer, msg + *pos, count))
        return -EFAULT;
    *pos += count;
    return count;
}

static const struct proc_ops proc_fops = {
    .proc_write = cmd_write,
    .proc_read  = cmd_read,
};

static int __init ksu_cmd_init(void) {
    proc_entry = proc_create(PROC_NAME, 0600, NULL, &proc_fops);
    if (!proc_entry) {
        printk(KERN_ERR "KSU_CMD: Failed to create /proc/%s\n", PROC_NAME);
        return -ENOMEM;
    }
    printk(KERN_INFO "KSU_CMD: Module loaded. Use 'echo \"command\" > /proc/ksu_cmd' (root only)\n");
    return 0;
}

static void __exit ksu_cmd_exit(void) {
    remove_proc_entry(PROC_NAME, NULL);
    printk(KERN_INFO "KSU_CMD: Module unloaded\n");
}

module_init(ksu_cmd_init);
module_exit(ksu_cmd_exit);