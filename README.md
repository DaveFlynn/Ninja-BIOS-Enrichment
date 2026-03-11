# Ninja BIOS Enrichment

This script reads BIOS details from Windows and writes them to Ninja custom fields. 

While the BIOS information is avaialble in the Ninja web UI, this information is not provided via the Nina API. Using custom fields, you're able to expose the BIOS information via the API.

## Script

`ninja_bios_enrichment.ps1`

## Custom fields expected in Ninja

Create the follpwing custom fields in Ninja to write the values to.

- `biosReleaseDate` (date)
- `biosVersion` (text)
- `biosManufacturer` (text)
- `biosSerialNumber` (text)

## What it does

1. Reads BIOS info from `Win32_BIOS` (CIM first, WMI fallback).
2. Normalizes/sanitizes values.
3. Writes values to Ninja custom fields via `Ninja-Property-Set`.
4. Verifies each write via `Ninja-Property-Get` with retry logic.

## Parameters

- `-NoWrite`  
  Collect-only mode. Does not write to Ninja fields.

- `-AsJson`  
  Outputs JSON (with legacy PS2 fallback).

## Add in Ninja (recommended)

Create this as an Automation script in Ninja:

`Administration -> Library -> Automation -> Add Automation -> New Script`

Use these settings:

- Name: your choice
- Description: your choice
- Category: `hardware`
- Language: `powershell`
- Operating system: `Windows`
- Architecture: `All`
- Run As: `System`

No variables or parameters are required.

## Standalone usage

You can run the script locally for data collection/testing:

```powershell
.\ninja_bios_enrichment.ps1 -NoWrite -AsJson
```

If run outside the Ninja agent script context, custom field writes are not available, so use `-NoWrite` for standalone runs.

## Notes

- Tested on Windows Server 2012, 2016, 2019, and 2022.
- On older/legacy endpoints, such as Server 2008, Ninja helper cmdlets may not be available in script context.
- The script is defensive for date formats and older PowerShell versions, but agent/runtime capability still controls whether custom fields can be written.
