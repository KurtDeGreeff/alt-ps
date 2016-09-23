function Get-Pipelist {
  <#
    .SYNOPSIS
        Displays the named pipes on your system, including the number
        of maximum instances and active instances for each pipe.
    .NOTES
        typedef struct _FILE_DIRECTORY_INFORMATION {
            ULONG NextEntryOffset;
            ULONG FileIndex;
            LARGE_INTEGER CreationTime;
            LARGE_INTEGER LastAccessTime;
            LARGE_INTEGER LastWriteTime;
            LARGE_INTEGER ChangeTime;
            LARGE_INTEGER EndOfFile;
            LARGE_INTEGER AllocationSize;
            ULONG FileAttributes;
            ULONG FileNameLength;
            WCHAR FileName[1];
        } FILE_DIRECTORY_INFORMATION, *PFILE_DIRECTORY_INFORMATION;
  #>
  begin {
    function private:Set-Delegate {
      param(
        [Parameter(Mandatory=$true, Position=0)]
        [ValidateNotNullOrEmpty()]
        [String]$Module,
        
        [Parameter(Mandatory=$true, Position=1)]
        [ValidateNotNullOrEmpty()]
        [String]$Function,
        
        [Parameter(Mandatory=$true, Position=2)]
        [ValidateNotNullOrEmpty()]
        [String]$Delegate
      )
      
      begin {
        [Object].Assembly.GetType(
          'Microsoft.Win32.Win32Native'
        ).GetMethods([Reflection.BindingFlags]40) |
        Where-Object {
          $_.Name -cmatch '\AGet(ProcA|ModuleH)'
        } | ForEach-Object {
          Set-Variable $_.Name $_ -Scope Global
        }
        
        if (($ptr = $GetProcAddress.Invoke($null, @(
          $GetModuleHandle.Invoke($null, @($Module)), $Function
        ))) -eq [IntPtr]::Zero) {
          throw New-Object InvalidOperationException(
            'Could not find specified signature.'
          )
        }
      }
      process { $proto = Invoke-Expression $Delegate }
      end {
        $method = $proto.GetMethod('Invoke')
        
        $returntype = $method.ReturnType
        $paramtypes = $method.GetParameters() |
                    Select-Object -ExpandProperty ParameterType
        
        $holder = New-Object Reflection.Emit.DynamicMethod(
          'Invoke', $returntype, $paramtypes, $proto
        )
        $il = $holder.GetILGenerator()
        0..($paramtypes.Length - 1) | ForEach-Object {
          $il.Emit([Reflection.Emit.OpCodes]::Ldarg, $_)
        }
        
        switch ([IntPtr]::Size) {
          4 { $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4, $ptr.ToInt32()) }
          8 { $il.Emit([Reflection.Emit.OpCodes]::Ldc_I8, $ptr.ToInt64()) }
        }
        
        $il.EmitCalli(
          [Reflection.Emit.OpCodes]::Calli,
          [Runtime.InteropServices.CallingConvention]::StdCall,
          $returntype, $paramtypes
        )
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        
        $holder.CreateDelegate($proto)
      }
    }
    
    $NtQueryDirectoryFile = Set-Delegate ntdll NtQueryDirectoryFile (
                        '[Func[Microsoft.Win32.SafeHandles.SafeFileHandle,' +
                        'IntPtr, IntPtr, IntPtr, [Byte[]], IntPtr, UInt32,' +
                                  'UInt32, Boolean, IntPtr, Boolean, Int32]]'
    )
    $NtQuerySystemInformation = Set-Delegate ntdll NtQuerySystemInformation `
                              '[Func[Int32, IntPtr, Int32, [Byte[]], Int32]]'
  }
  process {
    try {
      $sbi = [Runtime.InteropServices.Marshal]::AllocHGlobal(44)
      
      if ($NtQuerySystemInformation.Invoke(0, $sbi, 44, $null) -ne 0) {
        throw New-Object InvalidOperationException(
          'Could not retrieve system basic information.'
        )
      }
      
      $psz = [Runtime.InteropServices.Marshal]::ReadInt32($sbi, 8)
      
      if (($pipes = [Object].Assembly.GetType(
        'Microsoft.Win32.Win32Native'
      ).GetMethod(
        'CreateFile', [Reflection.BindingFlags]40
      ).Invoke($null, @(
        '\\.\pipe\', 0x80000000, [IO.FileShare]::Read, $null,
        [IO.FileMode]::Open, 0, [IntPtr]::Zero
      ))).IsInvalid) {
        throw New-Object InvalidOperationException(
          'Could not open pipes directory.'
        )
      }
      
      $query = $true
      $isb = New-Object Byte[]([IntPtr]::Size)
      $dir = [Runtime.InteropServices.Marshal]::AllocHGlobal($psz)
      
      $(while ($true) {
        if ($NtQueryDirectoryFile.Invoke(
          $pipes, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, $isb,
          $dir, $psz, 1, $false, [IntPtr]::Zero, $query
        ) -ne 0) { break }
        
        $tmp = $dir
        while ($true) {
          # NextEntryOffset - offset 0x00
          $neo = [Runtime.InteropServices.Marshal]::ReadInt32($tmp)
          # EndOfFile       - offset 0x28
          $eof = [Runtime.InteropServices.Marshal]::ReadInt64($tmp, 0x28)
          # AllocationSize  - offset 0x30
          $fas = [Runtime.InteropServices.Marshal]::ReadInt64($tmp, 0x30)
          # FileNameLength  - offset 0x3c
          $fnl = [Runtime.InteropServices.Marshal]::ReadInt32($tmp, 0x3c)
          # FileName        - offset 0x40
          $mov = switch ([IntPtr]::Size) { 4 {$tmp.ToInt32()} 8 {$tmp.ToInt64()}}
          
          New-Object PSObject -Property @{
            PipeName = [Runtime.InteropServices.Marshal]::PtrToStringUni(
              [IntPtr]($mov + 0x40), $fnl / 2
            )
            Instances = [BitConverter]::ToInt32([BitConverter]::GetBytes($eof), 0)
            MaxInstances = [BitConverter]::ToInt32([BitConverter]::GetBytes($fas), 0)
          }
          if ($neo -eq 0) { break }
          $tmp = [IntPtr]($mov + $neo)
        }
        $query = $false
      }) | Select-Object PipeName, Instances, MaxInstances
    }
    catch { $_ }
    finally {
      if ($dir) { [Runtime.InteropServices.Marshal]::FreeHGlobal($dir) }
      if ($pipes) { $pipes.Dispose() }
      if ($sbi) { [Runtime.InteropServices.Marshal]::FreeHGlobal($sbi) }
    }
  }
  end {}
}
