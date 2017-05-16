#!/usr/bin/env rspec
# encoding: utf-8

# Copyright (c) [2016-2017] SUSE LLC
#
# All Rights Reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms of version 2 of the GNU General Public License as published
# by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, contact SUSE LLC.
#
# To contact SUSE LLC about this file by physical or electronic mail, you may
# find current contact information at www.suse.com.

require_relative "../spec_helper"
require "storage"
require "y2storage"

describe Y2Storage::Proposal::VolumesGenerator do
  describe "#volumes" do
    using Y2Storage::Refinements::SizeCasts

    # Just to shorten
    let(:xfs) { Y2Storage::Filesystems::Type::XFS }
    let(:vfat) { Y2Storage::Filesystems::Type::VFAT }
    let(:swap) { Y2Storage::Filesystems::Type::SWAP }
    let(:btrfs) { Y2Storage::Filesystems::Type::BTRFS }

    let(:devicegraph) { instance_double("Y2Storage::Devicegraph") }
    let(:disk) { instance_double("Y2Storage::Disk", name: "/dev/sda") }
    let(:settings) { Y2Storage::ProposalSettings.new }
    let(:boot_checker) { instance_double("Y2Storage::BootRequirementChecker") }

    # Some reasonable defaults
    let(:swap_partitions) { [] }
    let(:arch) { :x86_64 }

    subject(:generator) { described_class.new(settings, devicegraph) }

    before do
      allow(Y2Storage::BootRequirementsChecker).to receive(:new).and_return boot_checker
      allow(boot_checker).to receive(:needed_partitions).and_return(
        Y2Storage::PlannedVolumesList.new(
          [
            Y2Storage::PlannedVolume.new("/one_boot", xfs),
            Y2Storage::PlannedVolume.new("/other_boot", vfat)
          ]
        )
      )
      allow(devicegraph).to receive(:disks).and_return [disk]
      allow(disk).to receive(:swap_partitions).and_return(swap_partitions)

      allow(Yast::Arch).to receive(:x86_64).and_return(arch == :x86_64)
      allow(Yast::Arch).to receive(:s390).and_return(arch == :s390)
    end

    it "returns a list of volumes" do
      expect(subject.volumes(:desired)).to be_a Y2Storage::PlannedVolumesList
    end

    it "includes the volumes needed by BootRequirementChecker" do
      expect(subject.volumes(:desired)).to include(
        an_object_having_attributes(mount_point: "/one_boot", filesystem_type: xfs),
        an_object_having_attributes(mount_point: "/other_boot", filesystem_type: vfat)
      )
    end

    # This swap sizes are currently hard-coded
    context "swap volumes" do
      before { settings.enlarge_swap_for_suspend = false }

      let(:swap_volumes) { subject.volumes(:desired).select { |v| v.mount_point == "swap" } }

      context "if there is no previous swap partition" do
        let(:swap_partitions) { [] }

        it "includes a brand new swap volume and no swap reusing" do
          expect(swap_volumes).to contain_exactly(an_object_having_attributes(reuse: nil))
        end
      end

      context "if the existing swap partition is not big enough" do
        let(:swap_partitions) { [partition_double("/dev/sdaX", 1.GiB)] }

        it "includes a brand new swap volume and no swap reusing" do
          expect(swap_volumes).to contain_exactly(an_object_having_attributes(reuse: nil))
        end
      end

      context "if the existing swap partition is big enough" do
        let(:swap_partitions) { [partition_double("/dev/sdaX", 3.GiB)] }

        context "if proposing an LVM setup" do
          before { settings.use_lvm = true }

          it "includes a brand new swap volume and no swap reusing" do
            expect(swap_volumes).to contain_exactly(an_object_having_attributes(reuse: nil))
          end
        end

        context "if proposing a partition-based setup" do
          context "without encryption" do
            it "includes a volume to reuse the existing swap and no new swap" do
              expect(swap_volumes).to contain_exactly(
                an_object_having_attributes(reuse: "/dev/sdaX")
              )
            end
          end

          context "with encryption" do
            before { settings.encryption_password = "12345678" }

            it "includes a brand new swap volume and no swap reusing" do
              expect(swap_volumes).to contain_exactly(
                an_object_having_attributes(reuse: nil)
              )
            end
          end
        end
      end

      context "if proposing a partition-based setup" do
        context "without encryption" do
          it "proposes a plain partition" do
            expect(swap_volumes).to contain_exactly(
              an_object_having_attributes(
                class: Y2Storage::PlannedDevices::Partition, encryption_password: nil
              )
            )
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          it "proposes an encrypted partition" do
            expect(swap_volumes).to contain_exactly(
              an_object_having_attributes(
                class: Y2Storage::PlannedDevices::Partition, encryption_password: "12345678"
              )
            )
          end
        end
      end

      context "if proposing an LVM-based setup" do
        before { settings.use_lvm = true }

        context "without encryption" do
          it "proposes a plain logical volume with the right name" do
            expect(swap_volumes).to contain_exactly(
              an_object_having_attributes(
                class:               Y2Storage::PlannedDevices::LvmLv,
                encryption_password: nil,
                logical_volume_name: "swap"
              )
            )
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          # Encryption is performed at PV level, not at LV one
          it "proposes a plain logical volume with the right name" do
            expect(swap_volumes).to contain_exactly(
              an_object_having_attributes(
                class:               Y2Storage::PlannedDevices::LvmLv,
                encryption_password: nil,
                logical_volume_name: "swap"
              )
            )
          end
        end
      end

      context "without enlarge_swap_for_suspend" do
        it "plans a small swap volume" do
          expect(swap_volumes.first.min).to eq 2.GiB
          expect(swap_volumes.first.max).to eq 2.GiB
        end
      end

      context "with enlarge_swap_for_suspend" do
        before do
          settings.enlarge_swap_for_suspend = true
        end

        it "plans a bigger swap volume" do
          expect(swap_volumes.first.min).to eq 8.GiB
          expect(swap_volumes.first.max).to eq 8.GiB
        end
      end
    end

    context "with use_separate_home" do
      before do
        settings.use_separate_home = true
        settings.home_min_size = 4.GiB
        settings.home_max_size = Y2Storage::DiskSize.unlimited
        settings.home_filesystem_type = xfs
      end

      let(:home) { subject.volumes(:desired).detect { |v| v.mount_point == "/home" } }

      it "includes a /home planned device with the configured settings" do
        expect(home).to have_attributes(
          mount_point:     "/home",
          min:             settings.home_min_size,
          max:             settings.home_max_size,
          filesystem_type: settings.home_filesystem_type
        )
      end

      context "if proposing a partition-based setup" do
        context "without encryption" do
          it "proposes /home to be a plain partition" do
            expect(home).to be_a Y2Storage::PlannedDevices::Partition
            expect(home.encrypt?).to eq false
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          it "proposes /home to be an encrypted partition" do
            expect(home).to be_a Y2Storage::PlannedDevices::Partition
            expect(home.encrypt?).to eq true
            expect(home.encryption_password).to eq "12345678"
          end
        end
      end

      context "if proposing an LVM-based setup" do
        before { settings.use_lvm = true }

        context "without encryption" do
          it "proposes /home to be a plain logical volume with the right name" do
            expect(home).to be_a Y2Storage::PlannedDevices::LvmLv
            expect(home.encrypt?).to eq false
            expect(home.logical_volume_name).to eq "home"
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          # Encryption is performed at PV level, not at LV one
          it "proposes /home to be a plain logical volume with the right name" do
            expect(home).to be_a Y2Storage::PlannedDevices::LvmLv
            expect(home.encrypt?).to eq false
            expect(home.logical_volume_name).to eq "home"
          end
        end
      end
    end

    context "without use_separate_home" do
      before do
        settings.use_separate_home = false
      end

      it "does not include a /home volume" do
        expect(subject.volumes(:desired)).to_not include(
          an_object_having_attributes(mount_point: "/home")
        )
      end
    end

    describe "setting the properties of the root partition" do
      before do
        settings.root_base_size = 10.GiB
        settings.root_max_size = 20.GiB
        settings.btrfs_increase_percentage = 75
      end

      let(:root) { subject.volumes(:desired).detect { |v| v.mount_point == "/" } }

      context "if proposing a partition-based setup" do
        context "without encryption" do
          it "proposes / to be a plain partition" do
            expect(root).to be_a Y2Storage::PlannedDevices::Partition
            expect(root.encrypt?).to eq false
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          it "proposes / to be an encrypted partition" do
            expect(root).to be_a Y2Storage::PlannedDevices::Partition
            expect(root.encrypt?).to eq true
            expect(root.encryption_password).to eq "12345678"
          end
        end
      end

      context "if proposing an LVM-based setup" do
        before { settings.use_lvm = true }

        context "without encryption" do
          it "proposes / to be a plain logical volume with the right name" do
            expect(root).to be_a Y2Storage::PlannedDevices::LvmLv
            expect(root.encrypt?).to eq false
            expect(root.logical_volume_name).to eq "root"
          end
        end

        context "with encryption" do
          before { settings.encryption_password = "12345678" }

          # Encryption is performed at PV level, not at LV one
          it "proposes / to be a plain logical volume with the right name" do
            expect(root).to be_a Y2Storage::PlannedDevices::LvmLv
            expect(root.encrypt?).to eq false
            expect(root.logical_volume_name).to eq "root"
          end
        end
      end

      context "with a non-Btrfs filesystem" do
        before do
          settings.root_filesystem_type = xfs
        end

        it "uses the normal sizes" do
          expect(subject.volumes(:min)).to include(
            an_object_having_attributes(
              mount_point:     "/",
              min:             10.GiB,
              max:             20.GiB,
              filesystem_type: xfs
            )
          )

          expect(subject.volumes(:desired)).to include(
            an_object_having_attributes(
              mount_point:     "/",
              min:             20.GiB,
              max:             20.GiB,
              filesystem_type: xfs
            )
          )
        end
      end

      context "if Btrfs is used" do
        let(:root) { subject.volumes(:desired).detect { |v| v.mount_point == "/" } }
        # For subvolumes tests
        let(:arch) { :s390 }

        before do
          settings.root_filesystem_type = btrfs
        end

        it "increases all the sizes by btrfs_increase_percentage" do
          expect(subject.volumes(:min)).to include(
            an_object_having_attributes(
              mount_point:     "/",
              min:             17.5.GiB,
              max:             35.GiB,
              filesystem_type: btrfs
            )
          )

          expect(subject.volumes(:desired)).to include(
            an_object_having_attributes(
              mount_point:     "/",
              min:             35.GiB,
              max:             35.GiB,
              filesystem_type: btrfs
            )
          )
        end

        it "has subvolumes" do
          expect(root.subvolumes).not_to be_nil
          expect(root.subvolumes?).to be true
        end

        it "has a subvolume var/log" do
          expect(root.subvolumes).to include(
            an_object_having_attributes(
              path:          "var/log",
              copy_on_write: true,
              archs:         nil
            )
          )
        end

        it "has a NoCOW subvolume var/lib/mariadb" do
          expect(root.subvolumes).to include(
            an_object_having_attributes(
              path:          "var/lib/mariadb",
              copy_on_write: false,
              archs:         nil
            )
          )
        end

        it "has an arch-specific subvolume boot/grub2/s390x-emu on s390" do
          expect(root.subvolumes).to include(
            an_object_having_attributes(
              path:          "boot/grub2/s390x-emu",
              copy_on_write: true,
              archs:         ["s390"]
            )
          )
        end

        it "does not have an arch-specific subvolume boot/grub2/x86_64-efi on s390" do
          expect(root.subvolumes).not_to include(
            an_object_having_attributes(
              path:          "boot/grub2/x86_64-efi",
              copy_on_write: true,
              archs:         ["x86_64"]
            )
          )
        end
      end
    end
  end
end
