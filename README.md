.SYNOPSIS
    Manage VMware VDS Port Groups interactively - export, import, or delete.

.DESCRIPTION
    Connects to a vCenter server and presents interactive menus to select
    a VDS switch and port groups to act on. Supports three modes:

      Export  - Export selected port groups to zip files in the backup directory.
      Import  - Import selected zip files to a chosen switch, with optional renaming.
      Delete  - Delete selected port groups from a chosen switch (with confirmation).

    All activity is written to both the console and a timestamped log file.

.PARAMETER vCenterServer
    FQDN or IP of the vCenter server to connect to.

.PARAMETER BackupDirectory
    Directory used to store exported zip files (Export mode) or read them from (Import mode).

.PARAMETER Mode
    The operation to perform: Export, Import, or Delete. This parameter is mandatory.

.PARAMETER LogDirectory
    Directory to write log files to. Defaults to a "Logs" subfolder inside BackupDirectory.

.PARAMETER CredentialPath
    Path to a saved encrypted credential file. Defaults to ~\.vcenter_cred.xml.
    Use -SaveCredential on first run to create this file.

.PARAMETER SaveCredential
    Prompts for credentials, saves them encrypted to CredentialPath, then exits.
    Run this once before first use.

.PARAMETER NamePrefix
    Optional prefix to prepend to imported port group names (Import mode only).
    e.g. -NamePrefix "NEW-" renames "HB-VLAN100-PRD" to "NEW-HB-VLAN100-PRD".

.PARAMETER NameSuffix
    Optional suffix to append to imported port group names (Import mode only).
    e.g. -NameSuffix "-v2" renames "HB-VLAN100-PRD" to "HB-VLAN100-PRD-v2".

.EXAMPLE
    # Save credentials once before first use
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -SaveCredential

.EXAMPLE
    # Export selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Export

.EXAMPLE
    # Import selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Import

.EXAMPLE
    # Import and rename port groups with a prefix and suffix
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Import -NamePrefix "NEW-" -NameSuffix "-v2"

.EXAMPLE
    # Delete selected port groups
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Delete

.EXAMPLE
    # Use a custom log directory
    .\Manage-VDSPortGroups.ps1 -vCenterServer "vcenter.corp.com" -BackupDirectory "C:\Backups\VDS" -Mode Export -LogDirectory "C:\Logs"
