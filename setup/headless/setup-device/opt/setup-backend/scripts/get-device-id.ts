/**
 * Print the device ID for this machine. Mirrors the backend registration logic.
 * Requires sudo for dmidecode access.
 *
 * Usage:
 *   pnpm exec tsx scripts/get-device-id.ts
 */
import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

/**
 * Mirrors the device ID logic from CI Hub backend registration service.
 *
 * 1. Try `dmidecode -s system-serial-number` (requires root)
 * 2. Fall back to /sys/class/dmi/id/product_uuid
 */
function getDeviceId(): string {
  try {
    const serial = execSync('sudo dmidecode -s system-serial-number', {
      timeout: 5000,
      encoding: 'utf-8',
    }).trim();

    if (serial && serial !== 'Not Specified' && serial.toLowerCase() !== 'to be filled by o.e.m.' && serial !== 'Default string') {
      return serial;
    }

    console.error(`dmidecode returned unusable value: "${serial}", falling back to hardware UUID`);
  } catch {
    console.error('dmidecode failed, falling back to hardware UUID');
  }

  try {
    return readFileSync('/sys/class/dmi/id/product_uuid', 'utf-8').trim();
  } catch {
    console.error('Could not read /sys/class/dmi/id/product_uuid');
  }

  try {
    return readFileSync('/etc/machine-id', 'utf-8').trim();
  } catch {
    throw new Error('Unable to determine device ID from any source');
  }
}

console.log(getDeviceId());