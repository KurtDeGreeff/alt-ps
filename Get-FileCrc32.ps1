function Get-FileCrc32 {
  param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({Test-Path $_})]
    [ValidateNotNullOrEmpty()]
    [String]$FilePath
  )
  
  begin {
    @(
      [Runtime.InteropServices.CallingConvention],
      [Runtime.InteropServices.HandleRef],
      [Reflection.Emit.OpCodes]
    ) | ForEach-Object {
      $keys = ($ta = [PSObject].Assembly.GetType(
        'System.Management.Automation.TypeAccelerators'
      ))::Get.Keys
      $collect = @()
    }{
      if ($keys -notcontains $_.Name) {
        $ta::Add($_.Name, $_)
      }
      $collect += $_.Name
    }
    
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
        [Regex].Assembly.GetType(
          'Microsoft.Win32.UnsafeNativeMethods'
        ).GetMethods() | Where-Object {
          $_.Name -cmatch '\AGet(ProcA|ModuleH)'
        } | ForEach-Object {
          Set-Variable $_.Name $_
        }
        
        $ptr = $GetProcAddress.Invoke($null, @(
          [HandleRef](New-Object HandleRef(
            (New-Object IntPtr), $GetModuleHandle.Invoke($null, @($Module))
          )), $Function
        ))
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
          $il.Emit([OpCodes]::Ldarg, $_)
        }
        
        switch ([IntPtr]::Size) {
          4 { $il.Emit([OpCodes]::Ldc_I4, $ptr.ToInt32()) }
          8 { $il.Emit([OpCodes]::Ldc_I8, $ptr.ToInt64()) }
        }
        $il.EmitCalli(
          [OpCodes]::Calli, [CallingConvention]::StdCall, $returntype, $paramtypes
        )
        $il.Emit([OpCodes]::Ret)
        
        $holder.CreateDelegate($proto)
      }
    }
    
    $FilePath = Resolve-Path $FilePath
    $RtlComputeCrc32 = Set-Delegate ntdll RtlComputeCrc32 `
                                           '[Func[UInt32, [Byte[]], Int32, UInt32]]'
  }
  process {
    try {
      if (($fs = [IO.File]::OpenRead($FilePath)).Length -eq 0) {
        throw New-Object InvalidOperationException('File is empty.')
      }
      
      [Byte[]]$buf = New-Object Byte[] $fs.Length
      [UInt32]$crc = 0
      
      while (($read = $fs.Read($buf, 0, $buf.Length)) -ne 0) {
        $crc = $RtlComputeCrc32.Invoke($crc, $buf, $read)
      }
      '0x{0:X}' -f $crc
    }
    catch { $_.Exception }
    finally {
      if ($fs -ne $null) {
        $fs.Dispose()
        $fs.Close()
      }
    }
  }
  end {
    $collect | ForEach-Object { [void]$ta::Remove($_) }
  }
}
