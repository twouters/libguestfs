(* guestfs-inspection
 * Copyright (C) 2009-2018 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

open Printf

open Std_utils

(* Enumerate block devices (including MD, LVM, LDM and partitions) and use
 * vfs-type to check for filesystems on devices.  Some block devices cannot
 * contain filesystems, so we filter them out.
 *)
let rec list_filesystems () =
  let has_lvm2 = Optgroups.lvm2_available () in
  let has_ldm = Optgroups.ldm_available () in

  (* Devices. *)
  let devices = Devsparts.list_devices () in
  let devices = List.filter is_not_partitioned_device devices in
  let ret = List.filter_map check_with_vfs_type devices in

  (* Partitions. *)
  let partitions = Devsparts.list_partitions () in
  let partitions = List.filter is_not_ldm_partition partitions in
  let ret = ret @ List.filter_map check_with_vfs_type partitions in

  (* MD. *)
  let mds = Md.list_md_devices () in
  let mds = List.filter is_not_partitioned_device mds in
  let ret = ret @ List.filter_map check_with_vfs_type mds in

  (* LVM. *)
  let ret =
    if has_lvm2 then (
      let lvs = Lvm.lvs () in
      ret @ List.filter_map check_with_vfs_type lvs
    )
    else ret in

  (* LDM. *)
  let ret =
    if has_ldm then (
      let ldmvols = Ldm.list_ldm_volumes () in
      ret @ List.filter_map check_with_vfs_type ldmvols
    )
    else ret in

  List.flatten ret

(* Look to see if device can directly contain filesystem (RHBZ#590167).
 * Partitioned devices cannot contain filesystem, so we will exclude
 * such devices.
 *)
and is_not_partitioned_device device =
  assert (String.is_prefix device "/dev/");
  let dev_name = String.sub device 5 (String.length device - 5) in
  let dev_dir = "/sys/block/" ^ dev_name in

  (* Open the device's directory under /sys/block/<dev_name> and
   * look for entries starting with <dev_name>, eg. /sys/block/sda/sda1
   *)
  let is_device_partition file = String.is_prefix file dev_name in
  let files = Array.to_list (Sys.readdir dev_dir) in
  let has_partition = List.exists is_device_partition files in

  not has_partition

(* We should ignore Windows Logical Disk Manager (LDM) partitions,
 * because these are members of a Windows dynamic disk group.  Trying
 * to read them will cause errors (RHBZ#887520).  Assuming that
 * libguestfs was compiled with ldm support, we'll get the filesystems
 * on these later.
 *)
and is_not_ldm_partition partition =
  let device = Devsparts.part_to_dev partition in
  let partnum = Devsparts.part_to_partnum partition in
  let parttype = Parted.part_get_parttype device in

  let is_gpt = parttype = "gpt" in
  let is_mbr = parttype = "msdos" in
  let is_gpt_or_mbr = is_gpt || is_mbr in

  if is_gpt_or_mbr then (
    (* MBR partition id will be converted into corresponding GPT type. *)
    let gpt_type = Parted.part_get_gpt_type device partnum in
    match gpt_type with
    (* Windows Logical Disk Manager metadata partition. *)
    | "5808C8AA-7E8F-42E0-85D2-E1E90434CFB3"
      (* Windows Logical Disk Manager data partition. *)
      | "AF9B60A0-1431-4F62-BC68-3311714A69AD" -> false
    | _ -> true
  )
  else true

(* Use vfs-type to check for a filesystem of some sort of [device].
 * Returns [Some [device, vfs_type; ...]] if found (there may be
 * multiple devices found in the case of btrfs), else [None] if nothing
 * is found.
 *)
and check_with_vfs_type device =
  let mountable = Mountable.of_device device in
  let vfs_type =
    try Blkid.vfs_type mountable
    with exn ->
       if verbose () then
         eprintf "check_with_vfs_type: %s: %s\n"
                 device (Printexc.to_string exn);
       "" in

  if vfs_type = "" then
    Some [mountable, "unknown"]

  (* Ignore all "*_member" strings.  In libblkid these are returned
   * for things which are members of some RAID or LVM set, most
   * importantly "LVM2_member" which is a PV.
   *)
  else if String.is_suffix vfs_type "_member" then
    None

  (* Ignore LUKS-encrypted partitions.  These are also containers, as above. *)
  else if vfs_type = "crypto_LUKS" then
    None

  (* A single btrfs device can turn into many volumes. *)
  else if vfs_type = "btrfs" then (
    let vols = Btrfs.btrfs_subvolume_list mountable in

    (* Filter out the default subvolume.  You can access that by
     * simply mounting the whole device, so we will add the whole
     * device at the beginning of the returned list instead.
     *)
    let default_volume = Btrfs.btrfs_subvolume_get_default mountable in
    let vols =
      List.filter (
        fun { Structs.btrfssubvolume_id = id } -> id <> default_volume
      ) vols in

    Some (
      (mountable, vfs_type) (* whole device = default volume *)
      :: List.map (
           fun { Structs.btrfssubvolume_path = path } ->
             let mountable = Mountable.of_btrfsvol device path in
             (mountable, "btrfs")
         ) vols
      )
  )

  else
    Some [mountable, vfs_type]
