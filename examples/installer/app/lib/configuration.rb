module Configuration
end

# Configuration file for NixOS
class Configuration::NixOSConfiguration
  attr_reader :configuration

  def self.from_configuration(data)
    instance = self.new
    instance.instance_exec do
      @configuration = data
    end
    instance
  end

  def cpu_count()
    core_count = File.read("/proc/cpuinfo").split(/\n+/).grep(/^processor/).count
    # Why `/2`? Assume some big.LITTLE-ness, or even "low vs. high" cores.
    core_count / 2
  end

  def luks_name(part)
    [
      "LUKS",
      @configuration[:info][:hostname].upcase.gsub(/[-_.]/, "-"),
      part.upcase,
    ].join("-")
  end

  def device()
    # XXX this should come from the 
    "TODO"
  end

  def username()
    @configuration[:info][:username]
  end

  def hashed_password()
    return @hashed_password if @hashed_password
    password = @configuration[:info][:password]
    # FIXME insecure; Open3 should be preferred
    # but we're well on the other side of the airtight hatchway.
    # The info leak in the process list would imply much more dire consequences in a temporary installer system.
    @hashed_password = `echo -n #{password.shellescape} | mkpasswd --stdin --method=sha-512`.chomp
    @hashed_password
  end

  def imports_fragment()
<<EOF
imports = [
  (import <mobile-nixos/lib/configuration.nix> { device = #{device.to_json}; })
  ./hardware-configuration.nix
];
EOF
  end

  def system_fragment()
<<EOF
networking.hostName = #{@configuration[:info][:hostname].to_json};
EOF
  end

  def defaults_fragment()
<<EOF
#
# Opinionated defaults
#

# Use Network Manager
networking.wireless.enable = false;
networking.networkmanager.enable = true;

# Use PulseAudio
hardware.pulseaudio.enable = true;

# Enable Bluetooth
hardware.bluetooth.enable = true;

# Bluetooth audio
hardware.pulseaudio.package = pkgs.pulseaudioFull;

# Enable power management options
powerManagement.enable = true;
EOF
  end

  def phone_environment_fragment()
    case @configuration[:environment][:phone_environment].to_sym
    when :phosh
<<EOF
#
# Phosh configuration
#

services.xserver.desktopManager.phosh = {
  enable = true;
  user = #{username.to_json};
  group = "users";
};

programs.calls.enable = true;
hardware.sensor.iio.enable = true;
EOF
    when :plamo
<<EOF
#
# Plasma Mobile configuration
#

services.xserver = {
  enable = true;
  desktopManager.plasma5.mobile.enable = true;
  displayManager.defaultSession = "plasma-mobile";
  displayManager.autoLogin = {
    enable = true;
    user = #{username.to_json};
  };
  displayManager.lightdm = {
    enable = true;
    # Workaround for autologin only working at first launch.
    # A logout or session crashing will show the login screen otherwise.
    extraSeatDefaults = ''
      session-cleanup-script=${pkgs.procps}/bin/pkill -P1 -fx ${pkgs.lightdm}/sbin/lightdm
    '';
  };
  libinput.enable = true;
};
EOF
    end
  end

  def user_fragment()
<<EOF
#
# User configuration
#

users.users.#{username.to_json} = {
  isNormalUser = true;
  description = #{@configuration[:info][:fullname].to_json};
  hashedPassword = #{hashed_password.to_json};
  extraGroups = [
    "dialout"
    "feedbackd"
    "networkmanager"
    "video"
    "wheel"
  ];
};
EOF
  end

  def configuration_nix()
    fragments = [
      imports_fragment,
      system_fragment,
      defaults_fragment,
      phone_environment_fragment,
      user_fragment,
    ]

<<EOF
{ config, lib, pkgs, ... }:

{
#{fragments.map(&:indent).join("\n\n")}
}
EOF
  end

  def filesystems_fragment()
    fragments = [
<<EOF
fileSystems = {
  "/" = {
    device = "/dev/disk/by-uuid/#{@configuration[:filesystems][:rootfs][:uuid]}";
    fsType = "ext4";
  };
};
EOF
    ]
    if @configuration[:fde][:enable] then
fragments << <<EOF
boot.initrd.luks.devices = {
  #{luks_name("rootfs").to_json} = {
    device = "/dev/disk/by-uuid/#{@configuration[:filesystems][:luks][:uuid]}";
  };
};
EOF
    end

    fragments.join("\n")
  end

  def hardware_configuration_nix()
<<EOF
# NOTE: this file was generated by the Mobile NixOS installer.
{ config, lib, pkgs, ... }:

{
#{filesystems_fragment.indent}

  nix.maxJobs = lib.mkDefault #{cpu_count.to_json};
}
EOF
  end

  private

  def initialize()
  end
end

# "Broker" for the configuration data.
# This somewhat decouples the installation bits from the internal structure,
# even though in the end we're relying on the internal structure from the steps
# windows.
module Configuration
  extend self

  DESCRIPTION = [
    { path: [ :fde, :enable ],                    label: "FDE enabled" },
    { path: [ :info, :fullname ],                 label: "Full name" },
    { path: [ :info, :username ],                 label: "User name" },
    { path: [ :info, :hostname ],                 label: "Host name" },
    { path: [ :environment, :phone_environment ], label: "Phone environment", mapping: ->(v) do GUI::PhoneEnvironmentConfigurationWindow::ENVIRONMENTS.to_h[v] end },
  ]

  def luks_uuid()
    @luks_uuid ||= SecureRandom.uuid
  end

  def rootfs_uuid()
    @rootfs_uuid ||= SecureRandom.uuid
  end

  def label_for(part, prefix_length: 999)
    [
      raw_config[:info][:hostname].upcase.gsub(/[-_.]/, "_")[0..(prefix_length-1)],
      part.upcase,
    ].join("_")
  end

  # What's this?
  #
  # This is to make generation of the config easier.
  # Instead of relying on the intrinsic new UUID generated by e.g. mkfs.ext4
  # or crypsetup luksFormat, we provide the UUID, so we don't need to sniff
  # around for the UUID.
  #
  # There is no drawback in doing this.
  def filesystems_data()
    {
      luks: {
        # no label in LUKS v1
        uuid: luks_uuid,
      },
      rootfs: {
        # ext4 labels are 16 chars; 11 + "_ROOT"
        label: label_for("root", prefix_length: 11),
        uuid: rootfs_uuid,
      },
    }
  end

  def raw_config()
    GUI::SystemConfigurationStepsWindow.instance.configuration_data
  end

  def configuration_data
    raw_config.merge(
      {
        filesystems: filesystems_data,
      }
    )
  end

  def save_json!(path)
    File.write(path, configuration_data.to_json())
  end

  def save_configuration!(prefix)
    FileUtils.mkdir_p(prefix)
    File.write(
      File.join(prefix, "configuration.nix"),
      NixOSConfiguration.from_configuration(configuration_data).configuration_nix
    )
    File.write(
      File.join(prefix, "hardware-configuration.nix"),
      NixOSConfiguration.from_configuration(configuration_data).hardware_configuration_nix
    )
  end

  def configuration_description
    data = configuration_data
    DESCRIPTION.map do |description|
      value = data.dig(*description[:path])

      value = "yes" if value == true
      value = "no" if value == false
      if description[:mapping] then
        value = description[:mapping].call(value)
      end

      " - #{description[:label]}: #{value.inspect}"
    end
      .join("\n")
  end
end
