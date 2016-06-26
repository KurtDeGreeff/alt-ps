function Get-CPUID {
  <#
    .SYNOPSIS
        Queries the CPU for information about its type.
  #>
  begin {
    @(
      [Runtime.InteropServices.CallingConvention],
      [Runtime.InteropServices.GCHandle],
      [Runtime.InteropServices.Marshal],
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
    
    Add-Type -AssemblyName System.ServiceModel
    
    ([AppDomain]::CurrentDomain.GetAssemblies() |
    Where-Object {
      $_.ManifestModule.ScopeName.Equals(
        'System.ServiceModel.dll'
      )
    }).GetType(
      'System.ServiceModel.Channels.UnsafeNativeMethods'
    ).GetMethods([Reflection.BindingFlags]40) |
    Where-Object {
      $_.Name -cmatch '\AVirtual(Alloc|Free)'
    } | ForEach-Object { Set-Variable $_.Name $_ }
    
    [Byte[]]$bytes = switch ([IntPtr]::Size) {
      4 {
        0x55,                   #push  ebp
        0x8B, 0xEC,             #mov   ebp,  esp
        0x53,                   #push  ebx
        0x57,                   #push  edi
        0x8B, 0x45, 0x08,       #mov   eax,  dword ptr[ebp+8]
        0x0F, 0xA2,             #cpuid
        0x8B, 0x7D, 0x0C,       #mov   edi,  dword ptr[ebp+12]
        0x89, 0x07,             #mov   dword ptr[edi+0],  eax
        0x89, 0x5F, 0x04,       #mov   dword ptr[edi+4],  ebx
        0x89, 0x4F, 0x08,       #mov   dword ptr[edi+8],  ecx
        0x89, 0x57, 0x0C,       #mov   dword ptr[edi+12], edx
        0x5F,                   #pop   edi
        0x5B,                   #pop   ebx
        0x8B, 0xE5,             #mov   esp,  ebp
        0x5D,                   #pop   ebp
        0xC3                    #ret
      }
      8 {
        0x53,                   #push  rbx
        0x49, 0x89, 0xD0,       #mov   r8,  rdx
        0x89, 0xC8,             #mov   eax, ecx
        0x0F, 0xA2,             #cpuid
        0x41, 0x89, 0x40, 0x00, #mov   dword ptr[r8+0],  eax
        0x41, 0x89, 0x58, 0x04, #mov   dword ptr[r8+4],  ebx
        0x41, 0x89, 0x48, 0x08, #mov   dword ptr[r8+8],  ecx
        0x41, 0x89, 0x50, 0x0C, #mov   dword ptr[r8+12], edx
        0x5B,                   #pop   rbx
        0xC3                    #ret
      }
    }
  }
  process {
    try {
      $ptr = $VirtualAlloc.Invoke($null, @(
        [IntPtr]::Zero, [UIntPtr](New-Object UIntPtr($bytes.Length)),
        [UInt32](0x1000 -bor 0x2000), [UInt32]0x40
      ))
      
      [Marshal]::Copy($bytes, 0, $ptr, $bytes.Length)
      
      $proto  = [Action[Int32, [Byte[]]]]
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
        [OpCodes]::Calli, [CallingConvention]::Cdecl, $returntype, $paramtypes
      )
      $il.Emit([OpCodes]::Ret)
      
      $cpuid = $holder.CreateDelegate($proto)
      
      [Byte[]]$buf = New-Object Byte[] 16
      $gch = [GCHandle]::Alloc($buf, 'Pinned')
      $cpuid.Invoke(0, $buf)
      $gch.Free()
      
      "$(-join [Char[]]$buf[4..7])$(
            -join [Char[]]$buf[12..15]
      )$(-join [Char[]]$buf[8..11])"
    }
    catch { $_.Exception }
    finally {
      if ($ptr) {
        [void]$VirtualFree.Invoke($null, @($ptr, [UIntPtr]::Zero, [UInt32]0x8000))
      }
    }
  }
  end {
    $collect | ForEach-Object { [void]$ta::Remove($_) }
  }
}
