#!/usr/bin/env rspec

# Copyright (c) [2019] SUSE LLC
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

require_relative "spec_helper"
require "y2storage/encryption_method"

describe Y2Storage::EncryptionMethod do
  describe ".all" do
    it "returns a method for Luks1" do
      expect(described_class.all.map(&:to_sym)).to include(:luks1)
    end

    it "returns a method for a random swap" do
      expect(described_class.all.map(&:to_sym)).to include(:random_swap)
    end
  end

  describe ".find" do
    context "when looking for a known method" do
      it "returns the encryption method" do
        luks1 = described_class.find(:luks1)
        random_swap = described_class.find(:random_swap)

        expect(luks1).to be_a Y2Storage::EncryptionMethod
        expect(luks1.id).to eq(:luks1)

        expect(random_swap).to be_a Y2Storage::EncryptionMethod
        expect(random_swap.id).to eq(:random_swap)
      end
    end

    context "when looking for an unknown method" do
      it "returns nil" do
        expect(described_class.find("unknown value")).to be_nil
      end
    end
  end

  describe "#create_device" do
    before do
      devicegraph_stub(scenario)
    end

    let(:scenario) { "mixed_disks.yml" }
    let(:devicegraph) { Y2Storage::StorageManager.instance.staging }
    let(:device_name) { "/dev/sda1" }
    let(:device) { devicegraph.find_by_name(device_name) }

    let(:encryption_method) { described_class.find(method) }
    let(:encryption) { encryption_method.create_device(device, "cr_dev") }

    context "when using :luks1 method" do
      let(:method) { :luks1 }

      it "creates an encryption device for the given block device" do
        expect(encryption).to be_a Y2Storage::Encryption
        expect(encryption.blk_device).to eq(device)
      end

      it "uses a LUKS1 encryption type" do
        expect(encryption.type).to be Y2Storage::EncryptionType::LUKS1
      end
    end

    context "when using :random_swap method" do
      let(:method) { :random_swap }

      it "creates an encryption device for the given block device" do
        expect(encryption).to be_a Y2Storage::Encryption
        expect(encryption.blk_device).to eq(device)
      end

      it "uses a plain encryption type" do
        expect(encryption.type).to be Y2Storage::EncryptionType::PLAIN
      end
    end
  end

  describe "#to_sym" do
    let(:id) { :luks1 }
    let(:encryption_method) { described_class.find(id) }

    it "returns a symbol" do
      expect(encryption_method.to_sym).to be_a Symbol
    end

    it "matches with the encryption method id" do
      expect(encryption_method.to_sym).to eq(id)
    end
  end

  describe "#to_human_string" do
    let(:encryption_method) { described_class.find(:luks1) }

    it "returns the method label" do
      expect(encryption_method.to_human_string).to match(/luks1/i)
    end
  end

  describe "#eql?" do
    let(:luks1_method) { described_class.find(:luks1) }
    let(:random_swap_method) { described_class.find(:random_passwrod) }

    context "when comparing equal methods" do
      let(:luks1_method) { described_class.find(:luks1) }
      let(:another_luks1_method) { described_class.find(:luks1) }

      it "returns true" do
        expect(luks1_method.eql?(another_luks1_method)).to eq(true)
      end
    end

    context "when comparing different methods" do
      let(:luks1_method) { described_class.find(:luks1) }
      let(:random_swap_method) { described_class.find(:random_passwrod) }

      it "returns false" do
        expect(luks1_method.eql?(random_swap_method)).to eq(false)
      end
    end
  end

  describe ".for_device" do
    before do
      devicegraph_stub(scenario)
    end

    let(:devicegraph) { Y2Storage::StorageManager.instance.staging }
    let(:device) { devicegraph.find_by_name(device_name) }

    context "when the given encryption device is a LUKS1" do
      let(:scenario) { "encrypted_partition.xml" }
      let(:device_name) { "/dev/mapper/cr_sda1" }

      it "returns the LUKS1 encryption method" do
        encryption_method = described_class.for_device(device)

        expect(encryption_method).to be_a Y2Storage::EncryptionMethod
        expect(encryption_method.to_sym).to eq(:luks1)
      end
    end

    context "when the given encryption device is a random swap" do
      let(:scenario) { "encrypted_random_swap.xml" }
      let(:device_name) { "/dev/mapper/cr_vda3" }

      it "returns the RANDOM_SWAP encryption method" do
        encryption_method = described_class.for_device(device)

        expect(encryption_method).to be_a Y2Storage::EncryptionMethod
        expect(encryption_method.to_sym).to eq(:random_swap)
      end
    end
  end
end
