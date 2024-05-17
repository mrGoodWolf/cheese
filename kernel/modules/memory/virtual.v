// virtual.v: Virtual mapping management.
// Code is governed by the GPL-2.0 license.
// Copyright (C) 2021-2022 The Vinix authors.

module memory

import lib
import limine
import klock
import x86.cpu

fn C.text_start()
fn C.text_end()
fn C.rodata_start()
fn C.rodata_end()
fn C.data_start()
fn C.data_end()

pub const (
	pte_present = u64(1) << 0
	pte_writable = u64(1) << 1
	pte_user = u64(1) << 2
	pte_noexec = u64(1) << 63
)

__global (
	page_size       = u64(0x1000)
	kernel_pagemap  Pagemap
	vmm_initialised = bool(false)
)

pub struct Pagemap {
pub mut:
	l           klock.Lock
	top_level   &u64 = unsafe { nil }
	mmap_ranges []voidptr
}

fn C.get_kernel_end_addr() u64

pub fn new_pagemap() &Pagemap {
	mut top_level := &u64(pmm_alloc(1))
	if top_level == 0 {
		panic('new_pagemap() allocation failure')
	}

	// Import higher half from kernel pagemap
	mut p1 := &u64(u64(top_level) + higher_half)
	p2 := &u64(u64(kernel_pagemap.top_level) + higher_half)
	for i := u64(256); i < 512; i++ {
		unsafe {
			p1[i] = p2[i]
		}
	}
	return &Pagemap{
		top_level: top_level
		mmap_ranges: []voidptr{}
	}
}

pub fn (pagemap &Pagemap) virt2pte(virt u64, allocate bool) ?&u64 {
	pml4_entry := (virt & (u64(0x1ff) << 39)) >> 39
	pml3_entry := (virt & (u64(0x1ff) << 30)) >> 30
	pml2_entry := (virt & (u64(0x1ff) << 21)) >> 21
	pml1_entry := (virt & (u64(0x1ff) << 12)) >> 12

	pml4 := pagemap.top_level
	pml3 := get_next_level(pml4, pml4_entry, allocate) or { return none }
	pml2 := get_next_level(pml3, pml3_entry, allocate) or { return none }
	pml1 := get_next_level(pml2, pml2_entry, allocate) or { return none }

	return unsafe { &u64(u64(&pml1[pml1_entry]) + higher_half) }
}

pub fn (pagemap &Pagemap) virt2phys(virt u64) ?u64 {
	pte_p := pagemap.virt2pte(virt, false) or { return none }
	if unsafe { *pte_p } & 1 == 0 {
		return none
	}
	return unsafe { *pte_p } & ~u64(0xfff)
}

pub fn (mut pagemap Pagemap) switch_to() {
	top_level := pagemap.top_level

	asm volatile amd64 {
		mov cr3, top_level
		; ; r (top_level)
		; memory
	}
}

fn get_next_level(current_level &u64, index u64, allocate bool) ?&u64 {
	mut ret := &u64(0)

	mut entry := &u64(u64(current_level) + higher_half + index * 8)

	// Check if entry is present
	if unsafe { *entry } & 0x01 != 0 {
		// If present, return pointer to it
		ret = &u64(unsafe { *entry } & ~u64(0xfff))
	} else {
		if allocate == false {
			return none
		}

		// Else, allocate the page table
		ret = pmm_alloc(1)
		if ret == 0 {
			return none
		}
		unsafe { *entry = u64(ret) | 0b111 }
	}
	return ret
}

pub fn (mut pagemap Pagemap) unmap_page(virt u64) ? {
	pte_p := pagemap.virt2pte(virt, false) or { return none }

	unsafe { *pte_p = 0 }

	current_cr3 := cpu.read_cr3()
	if current_cr3 == u64(pagemap.top_level) {
		cpu.invlpg(virt)
	}
}

pub fn (mut pagemap Pagemap) flag_page(virt u64, flags u64) ? {
	pte_p := pagemap.virt2pte(virt, false) or {
		return none
	}

	unsafe { *pte_p &= ~u64(0xfff) }
	unsafe { *pte_p |= flags }

	current_cr3 := cpu.read_cr3()
	if current_cr3 == u64(pagemap.top_level) {
		cpu.invlpg(virt)
	}
}

pub fn (mut pagemap Pagemap) map_page(virt u64, phys u64, flags u64) ? {
	pagemap.l.acquire()
	defer {
		pagemap.l.release()
	}

	pml4_entry := (virt & (u64(0x1ff) << 39)) >> 39
	pml3_entry := (virt & (u64(0x1ff) << 30)) >> 30
	pml2_entry := (virt & (u64(0x1ff) << 21)) >> 21
	pml1_entry := (virt & (u64(0x1ff) << 12)) >> 12

	pml4 := pagemap.top_level
	pml3 := get_next_level(pml4, pml4_entry, true) or { return none }
	pml2 := get_next_level(pml3, pml3_entry, true) or { return none }
	mut pml1 := get_next_level(pml2, pml2_entry, true) or { return none }

	entry := &u64(u64(pml1) + higher_half + pml1_entry * 8)

	unsafe { *entry = phys | flags }
}

@[cinit]
@[_linker_section: '.requests']
__global (
	volatile kaddr_req = limine.LimineKernelAddressRequest{
		response: unsafe { nil }
	}
	volatile memmap_req = limine.LimineMemmapRequest{
		response: unsafe { nil }
	}
)

fn map_kernel_span(virt u64, phys u64, len u64, flags u64) {
	aligned_len := lib.align_up(len, page_size)

	print('vmm: Kernel: Mapping at 0x${phys:x} to 0x${virt:x}, length: 0x${aligned_len:x}\n')

	for i := u64(0); i < aligned_len; i += page_size {
		kernel_pagemap.map_page(virt + i, phys + i, flags) or {
			panic('vmm init failure')
		}
	}
}

pub fn vmm_init() {
	print('vmm: Kernel physical base: 0x${kaddr_req.response.physical_base:x}\n')
	print('vmm: Kernel virtual base: 0x${kaddr_req.response.virtual_base:x}\n')

	kernel_pagemap.top_level = pmm_alloc(1)
	if kernel_pagemap.top_level == 0 {
		panic('vmm_init() allocation failure')
	}

	// Since the higher half has to be shared amongst all address spaces,
	// we need to initialise every single higher half PML3 so they can be
	// shared.
	for i := u64(256); i < 512; i++ {
		// get_next_level will allocate the PML3s for us.
		get_next_level(kernel_pagemap.top_level, i, true) or { panic('vmm init failure') }
	}

	// Map kernel
	virtual_base := kaddr_req.response.virtual_base
	physical_base := kaddr_req.response.physical_base

	// Map kernel text
	text_virt := u64(voidptr(C.text_start))
	text_phys := (text_virt - virtual_base) + physical_base
	text_len := u64(voidptr(C.text_end)) - text_virt
	map_kernel_span(text_virt, text_phys, text_len, pte_present)

	// Map kernel rodata
	rodata_virt := u64(voidptr(C.rodata_start))
	rodata_phys := (rodata_virt - virtual_base) + physical_base
	rodata_len := u64(voidptr(C.rodata_end)) - rodata_virt
	map_kernel_span(rodata_virt, rodata_phys, rodata_len, pte_present | pte_noexec)

	// Map kernel data
	data_virt := u64(voidptr(C.data_start))
	data_phys := (data_virt - virtual_base) + physical_base
	data_len := u64(voidptr(C.data_end)) - data_virt
	map_kernel_span(data_virt, data_phys, data_len, pte_present | pte_noexec | pte_writable)

	for i := u64(0x1000); i < 0x100000000; i += page_size {
		kernel_pagemap.map_page(i, i, 0x03) or { panic('vmm init failure') }
		kernel_pagemap.map_page(i + higher_half, i, 0x03) or { panic('vmm init failure') }
	}

	memmap := memmap_req.response

	entries := memmap.entries
	for i := 0; i < memmap.entry_count; i++ {
		base := unsafe { lib.align_down(entries[i].base, page_size) }
		top := unsafe { lib.align_up(entries[i].base + entries[i].length, page_size) }
		if top <= u64(0x100000000) {
			continue
		}
		for j := base; j < top; j += page_size {
			if j < u64(0x100000000) {
				continue
			}
			kernel_pagemap.map_page(j, j, 0x03) or { panic('vmm init failure') }
			kernel_pagemap.map_page(j + higher_half, j, 0x03) or { panic('vmm init failure') }
		}
	}

	kernel_pagemap.switch_to()

	vmm_initialised = true
}
