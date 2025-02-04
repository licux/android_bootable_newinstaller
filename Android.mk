# Copyright 2009-2014, The Android-x86 Open Source Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

ifneq ($(filter x86%,$(TARGET_ARCH)),)
LOCAL_PATH := $(call my-dir)
include $(CLEAR_VARS)

include $(CLEAR_VARS)
LOCAL_IS_HOST_MODULE := true
LOCAL_SRC_FILES := rpm/qemu-android
LOCAL_MODULE := $(notdir $(LOCAL_SRC_FILES))
LOCAL_MODULE_TAGS := debug
LOCAL_MODULE_CLASS := EXECUTABLES
LOCAL_POST_INSTALL_CMD := $(hide) sed -i "s|CMDLINE|$(BOARD_KERNEL_CMDLINE)|" $(HOST_OUT_EXECUTABLES)/$(LOCAL_MODULE)
include $(BUILD_PREBUILT)

VER ?= $$(date +"%F")

# use squashfs for iso, unless explictly disabled
ifneq ($(USE_SQUASHFS),0)
MKSQUASHFS := $(MAKE_SQUASHFS)

define build-squashfs-target
	$(hide) $(MKSQUASHFS) $(1) $(2) -noappend -comp gzip
endef
endif

initrd_dir := $(LOCAL_PATH)/initrd
initrd_bin := \
	$(initrd_dir)/init \
	$(wildcard $(initrd_dir)/*/*)

systemimg  := $(PRODUCT_OUT)/system-qemu.img
vendorimg  := $(PRODUCT_OUT)/vendor-qemu.img


TARGET_INITRD_OUT := $(PRODUCT_OUT)/initrd
INITRD_RAMDISK := $(TARGET_INITRD_OUT).img
$(INITRD_RAMDISK): $(initrd_bin) $(systemimg) $(TARGET_INITRD_SCRIPTS) | $(ACP) $(MKBOOTFS)
	$(hide) rm -rf $(TARGET_INITRD_OUT)
	mkdir -p $(addprefix $(TARGET_INITRD_OUT)/,android hd iso lib mnt proc scripts sfs sys tmp)
	$(if $(TARGET_INITRD_SCRIPTS),$(ACP) -p $(TARGET_INITRD_SCRIPTS) $(TARGET_INITRD_OUT)/scripts)
	ln -s /bin/ld-linux.so.2 $(TARGET_INITRD_OUT)/lib
	echo "VER=$(VER)" > $(TARGET_INITRD_OUT)/scripts/00-ver
	$(if $(RELEASE_OS_TITLE),echo "OS_TITLE=$(RELEASE_OS_TITLE)" >> $(TARGET_INITRD_OUT)/scripts/00-ver)
	$(if $(INSTALL_PREFIX),echo "INSTALL_PREFIX=$(INSTALL_PREFIX)" >> $(TARGET_INITRD_OUT)/scripts/00-ver)
	$(MKBOOTFS) $(<D) $(TARGET_INITRD_OUT) | gzip -9 > $@

INSTALL_RAMDISK := $(PRODUCT_OUT)/install.img
INSTALLER_BIN := $(TARGET_INSTALLER_OUT)/sbin/efibootmgr
$(INSTALL_RAMDISK): $(wildcard $(LOCAL_PATH)/install/*/* $(LOCAL_PATH)/install/*/*/*/*) $(INSTALLER_BIN) | $(MKBOOTFS)
	$(if $(TARGET_INSTALL_SCRIPTS),mkdir -p $(TARGET_INSTALLER_OUT)/scripts; $(ACP) -p $(TARGET_INSTALL_SCRIPTS) $(TARGET_INSTALLER_OUT)/scripts)
	$(MKBOOTFS) $(dir $(dir $(<D))) $(TARGET_INSTALLER_OUT) | gzip -9 > $@

isolinux_files := $(addprefix external/syslinux/bios/com32/, \
	../core/isolinux.bin \
	chain/chain.c32 \
	elflink/ldlinux/ldlinux.c32 \
	lib/libcom32.c32 \
	libutil/libutil.c32 \
	menu/vesamenu.c32)

boot_dir := $(PRODUCT_OUT)/boot
$(boot_dir): $(shell find $(LOCAL_PATH)/boot -type f | sort -r) $(isolinux_files) $(systemimg) $(INSTALL_RAMDISK) $(GENERIC_X86_CONFIG_MK) | $(ACP)
	$(hide) rm -rf $@
	$(ACP) -pr $(dir $(<D)) $@
	$(ACP) -pr $(dir $(<D))../install/grub2/efi $@
	$(ACP) $(isolinux_files) $@/isolinux
	img=$@/boot/grub/efi.img; dd if=/dev/zero of=$$img bs=1M count=4; \
	mkdosfs -n EFI $$img; mmd -i $$img ::boot; \
	mcopy -si $$img $@/efi ::; mdel -i $$img ::efi/boot/*.cfg

BUILT_IMG := $(addprefix $(PRODUCT_OUT)/,ramdisk.img initrd.img install.img) $(systemimg) $(vendorimg)
BUILT_IMG += $(if $(TARGET_PREBUILT_KERNEL),$(TARGET_PREBUILT_KERNEL),$(PRODUCT_OUT)/kernel)

GENISOIMG := $(if $(shell which xorriso 2> /dev/null),xorriso -as mkisofs,genisoimage)
ISO_IMAGE := $(PRODUCT_OUT)/$(TARGET_PRODUCT).iso
$(ISO_IMAGE): $(boot_dir) $(BUILT_IMG)
	@echo ----- Making iso image ------
	$(hide) sed -i "s|\(Installation CD\)\(.*\)|\1 $(VER)|; s|CMDLINE|$(BOARD_KERNEL_CMDLINE)|" $</isolinux/isolinux.cfg
	$(hide) sed -i "s|VER|$(VER)|; s|CMDLINE|$(BOARD_KERNEL_CMDLINE)|" $</efi/boot/android.cfg
	sed -i "s|OS_TITLE|$(if $(RELEASE_OS_TITLE),$(RELEASE_OS_TITLE),Android-x86)|" $</isolinux/isolinux.cfg $</efi/boot/android.cfg
	$(GENISOIMG) -vJURT -b isolinux/isolinux.bin -c isolinux/boot.cat \
		-no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
		-input-charset utf-8 -V "$(if $(RELEASE_OS_TITLE),$(RELEASE_OS_TITLE),Android-x86) LiveCD" -o $@ $^
	$(hide) isohybrid --uefi $@ || echo -e "isohybrid not found.\nInstall syslinux 4.0 or higher if you want to build a usb bootable iso."
	@echo -e "\n\n$@ is built successfully.\n\n"

rpm: $(wildcard $(LOCAL_PATH)/rpm/*) $(BUILT_IMG)
	@echo ----- Making an rpm ------
	OUT=$(abspath $(PRODUCT_OUT)); mkdir -p $$OUT/rpm/BUILD; rm -rf $$OUT/rpm/RPMS/*; $(ACP) $< $$OUT; \
	echo $(VER) | grep -vq rc; EPOCH=$$((-$$? + `echo $(VER) | cut -d. -f1`)); \
	rpmbuild -bb --target=$(if $(filter x86,$(TARGET_ARCH)),i686,x86_64) -D"cmdline $(BOARD_KERNEL_CMDLINE)" \
		-D"_topdir $$OUT/rpm" -D"_sourcedir $$OUT" -D"systemimg $(notdir $(systemimg))" -D"ver $(VER)" -D"epoch $$EPOCH" \
		$(if $(BUILD_NAME_VARIANT),-D"name $(BUILD_NAME_VARIANT)") \
		-D"install_prefix $(if $(INSTALL_PREFIX),$(INSTALL_PREFIX),android-$(VER))" $(filter %.spec,$^); \
	mv $$OUT/rpm/RPMS/*/*.rpm $$OUT

.PHONY: iso_img usb_img efi_img rpm
iso_img: $(ISO_IMAGE)
usb_img: $(ISO_IMAGE)
efi_img: $(ISO_IMAGE)
initrd:  $(BUILT_IMG)

X86EMU_EXTRA_SIZE := 200000000
X86EMU_DISK_SIZE := $(shell echo ${BOARD_SYSTEMIMAGE_PARTITION_SIZE}+${BOARD_VENDORIMAGE_PARTITION_SIZE}+${X86EMU_EXTRA_SIZE} | bc)
X86EMU_TMP := x86emu_tmp

qcow2_img: $(BUILT_IMG)
	mkdir -p $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	cd $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}; mkdir data
	mv $(PRODUCT_OUT)/initrd.img $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	mv $(PRODUCT_OUT)/install.img $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	mv $(PRODUCT_OUT)/ramdisk.img $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	mv $(PRODUCT_OUT)/system-qemu.img $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	mv $(PRODUCT_OUT)/vendor-qemu.img $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}
	make_ext4fs -T -1 -l $(X86EMU_DISK_SIZE) $(PRODUCT_OUT)/${TARGET_PRODUCT}.img $(PRODUCT_OUT)/${X86EMU_TMP} $(PRODUCT_OUT)/${X86EMU_TMP}
	mv $(PRODUCT_OUT)/${X86EMU_TMP}/${TARGET_PRODUCT}/*.img $(PRODUCT_OUT)/
	qemu-img convert -c -f raw -O qcow2 $(PRODUCT_OUT)/${TARGET_PRODUCT}.img $(PRODUCT_OUT)/${TARGET_PRODUCT}-qcow2.img
	cd $(PRODUCT_OUT); qemu-img create -f qcow2 -b ./${TARGET_PRODUCT}-qcow2.img ./${TARGET_PRODUCT}.img

endif
