final: prev: {

  libraspberrypi = prev.callPackage ../pkgs/raspberrypi/libraspberrypi.nix {};

  raspberrypi-userland = final.libraspberrypi;

  raspberrypi-udev-rules = prev.callPackage ../pkgs/raspberrypi/udev-rules.nix {};

  raspberrypi-utils = prev.callPackage ../pkgs/raspberrypi/raspberrypi-utils.nix {};

  rpi-otp-derived-key = prev.callPackage ../pkgs/raspberrypi/rpi-otp-derived-key.nix {
    rpiOtpPrivateKey = final.rpi-otp-private-key;
  };

  rpi-otp-private-key = prev.callPackage ../pkgs/raspberrypi/rpi-otp-private-key.nix {
    libraspberrypi = final.libraspberrypi;
  };

  rpi-userland = final.libraspberrypi;

  rpicam-apps = prev.callPackage ../pkgs/raspberrypi/rpicam-apps.nix {
    libcamera = final.libcamera_rpi;
  };

}
