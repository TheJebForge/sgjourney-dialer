# Stargate Journey Dialer Program
Program for ComputerCraft to control SGJourney stargates

## Features
- Able to dial all 5 types of Stargates
- Dedicated name server to keep a list of gates and waypoints
- Call by name functionality
- Monitor support

## How To Use

### Name server
- Place a computer and an ender modem
- Chunkload the computer to ensure it's always going to be available
- Use wget to download `nameServer.lua`
- Rename the file to `startup.lua`
- Reboot the computer

### Dialing computer
- Attach a stargate interface to the stargate
- Put a computer next to it or connect the interface to computer using wired modems
- Use wget to download `dialer.lua`
- Rename it to `startup.lua`
- Reboot the computer

If you only have basic or crystal interface attached to the computer, you'll be prompted to provide the address of the gate
You can use PDA to get the address, copy it and paste it into the computer
