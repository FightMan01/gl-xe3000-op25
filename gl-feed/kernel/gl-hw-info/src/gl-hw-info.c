// SPDX-License-Identifier: GPL-2.0
/*
 * /proc/gl-hw-info for GL.iNet userspace (cloud client, MCU daemon, ...).
 *
 * GL's stock kernel fills these files itself from its device tree and the
 * factory partition. Here the module only provides the files; the
 * gl-hw-info init script writes each value once at boot. Every entry is
 * writable by root only, and device_key is readable by root only.
 */

#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#define GL_HW_INFO_MAX	8192

struct gl_hw_entry {
	const char *name;
	umode_t mode;
	char *value;
	size_t len;
};

static struct gl_hw_entry entries[] = {
	{ "model", 0644 },
	{ "wan", 0644 },
	{ "lan", 0644 },
	{ "build-in-modem", 0644 },
	{ "pcie-bus", 0644 },
	{ "usb-port", 0644 },
	{ "modem-reset", 0644 },
	{ "fan", 0644 },
	{ "flash_size", 0644 },
	{ "temperature", 0644 },
	{ "reset-button", 0644 },
	{ "radio", 0644 },
	{ "mcu", 0644 },
	{ "cfg-partition", 0644 },
	{ "dfs", 0644 },
	{ "sim", 0644 },
	{ "device_mac", 0644 },
	{ "device_ddns", 0644 },
	{ "device_sn", 0644 },
	{ "device_sn_bak", 0644 },
	{ "country_code", 0644 },
	{ "device_cert", 0644 },
	{ "device_key", 0600 },
};

static DEFINE_MUTEX(gl_hw_lock);
static struct proc_dir_entry *gl_hw_dir;

static int gl_hw_show(struct seq_file *m, void *v)
{
	struct gl_hw_entry *e = m->private;

	mutex_lock(&gl_hw_lock);
	if (e->value)
		seq_write(m, e->value, e->len);
	mutex_unlock(&gl_hw_lock);
	return 0;
}

static int gl_hw_open(struct inode *inode, struct file *file)
{
	return single_open(file, gl_hw_show, pde_data(inode));
}

static ssize_t gl_hw_write(struct file *file, const char __user *buf,
			   size_t count, loff_t *ppos)
{
	struct gl_hw_entry *e = pde_data(file_inode(file));
	char *value;

	if (count > GL_HW_INFO_MAX)
		return -EFBIG;

	value = memdup_user_nul(buf, count);
	if (IS_ERR(value))
		return PTR_ERR(value);

	mutex_lock(&gl_hw_lock);
	kfree_sensitive(e->value);
	e->value = value;
	e->len = count;
	mutex_unlock(&gl_hw_lock);

	return count;
}

static const struct proc_ops gl_hw_ops = {
	.proc_open	= gl_hw_open,
	.proc_read	= seq_read,
	.proc_lseek	= seq_lseek,
	.proc_release	= single_release,
	.proc_write	= gl_hw_write,
};

static int __init gl_hw_info_init(void)
{
	int i;

	gl_hw_dir = proc_mkdir("gl-hw-info", NULL);
	if (!gl_hw_dir)
		return -ENOMEM;

	for (i = 0; i < ARRAY_SIZE(entries); i++) {
		if (!proc_create_data(entries[i].name, entries[i].mode,
				      gl_hw_dir, &gl_hw_ops, &entries[i])) {
			proc_remove(gl_hw_dir);
			return -ENOMEM;
		}
	}

	return 0;
}

static void __exit gl_hw_info_exit(void)
{
	int i;

	proc_remove(gl_hw_dir);
	for (i = 0; i < ARRAY_SIZE(entries); i++)
		kfree_sensitive(entries[i].value);
}

module_init(gl_hw_info_init);
module_exit(gl_hw_info_exit);

MODULE_DESCRIPTION("GL.iNet /proc/gl-hw-info compatibility");
MODULE_LICENSE("GPL");
