param([ValidateSet('Capture','CaptureDiagnostics','FocusPolicySelfTest','Restore','PreparePaste','ValidatePaste','Paste','Monitor','CopyImages','ClipboardSequence')][string]$Mode)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName Accessibility
$automationReferences = @(
  [System.Windows.Automation.ClientSettings].Assembly.Location
  [System.Windows.Automation.AutomationIdentifier].Assembly.Location
  [Accessibility.IAccessible].Assembly.Location
  [System.Collections.Generic.HashSet[int]].Assembly.Location
  [System.Diagnostics.Stopwatch].Assembly.Location
) | Select-Object -Unique
Add-Type -ReferencedAssemblies $automationReferences -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Automation;
public static class ClipBoardLineNative {
  private static bool automationInitialized;
  [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
  public static void InitializeAutomation() {
    if(automationInitialized)return;
    var providers=System.Reflection.Assembly.Load("UIAutomationClientsideProviders, Version=4.0.0.0, Culture=neutral, PublicKeyToken=31bf3856ad364e35");
    System.Windows.Automation.ClientSettings.RegisterClientSideProviderAssembly(providers.GetName());
    automationInitialized=true;
  }
  // Chrome can expose only generic panes through the managed UIA/MSAA proxy.
  // Resolve its explicit native accFocus chain and require IA2 editable state.
  // No accName, accValue, text, selection or editable-text method is called.
  [ComImport,Guid("6D5140C1-7436-11CE-8034-00AA006009FA"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  private interface IAccessibleServiceProvider {
    [PreserveSig] int QueryService(ref Guid service,ref Guid iid,out IntPtr result);
  }
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int IA2Int(IntPtr self,out int value);
  [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int IA2Window(IntPtr self,out IntPtr value);
  [StructLayout(LayoutKind.Sequential)] private struct GUITHREADINFO {
    public int size;public uint flags;public IntPtr active,focus,capture,menuOwner,moveSize,caret;public int left,top,right,bottom;
  }
  [DllImport("user32.dll")] private static extern bool GetGUIThreadInfo(uint thread,ref GUITHREADINFO info);
  [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window,uint flags);
  [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window,uint objectId,ref Guid iid,[MarshalAs(UnmanagedType.Interface)] out Accessibility.IAccessible result);
  private static int IA2Number(IntPtr pointer,int slot,out int value) {
    var method=Marshal.ReadIntPtr(Marshal.ReadIntPtr(pointer),slot*IntPtr.Size);
    return ((IA2Int)Marshal.GetDelegateForFunctionPointer(method,typeof(IA2Int)))(pointer,out value);
  }
  private static int IA2Handle(IntPtr pointer,out IntPtr value) {
    var method=Marshal.ReadIntPtr(Marshal.ReadIntPtr(pointer),42*IntPtr.Size);
    return ((IA2Window)Marshal.GetDelegateForFunctionPointer(method,typeof(IA2Window)))(pointer,out value);
  }
  private sealed class FocusSample {
    internal IntPtr Window;internal uint Owner;internal string Runtime;internal bool Editable,Secure,Loading;
    internal string Json { get { return "{\"handle\":\""+Window.ToInt64()+"\",\"processId\":"+Owner+",\"runtime\":\""+Runtime+"\",\"editable\":"+(Editable?"true":"false")+",\"secure\":"+(Secure?"true":"false")+"}"; } }
  }
  private static FocusSample Snapshot(IntPtr window,uint owner,string runtime,bool editable,bool secure,bool loading=false) {
    return new FocusSample {Window=window,Owner=owner,Runtime=runtime,Editable=editable,Secure=secure,Loading=loading};
  }
  private static bool LoadingDocument(int role,uint state,int states) {
    // Chromium's loading root is a BUSY, READONLY DOCUMENT. It is never an
    // editor; wait only for its explicit focus relation to become available.
    // https://source.chromium.org/chromium/chromium/src/+/main:content/browser/accessibility/accessibility_win_browsertest.cc
    return role==15&&(state&0x844)==0x844&&(state&0x20000001)==0&&(states&12)==0;
  }
  private static string lastCaptureTrace="{}";
  public static string CaptureTrace() {return lastCaptureTrace;}
  private static FocusSample CaptureResult(FocusSample result,string reason,int samples,int loading,int missing,long elapsed) {
    // Bounded capability metadata only, preserved even when capture rejects.
    lastCaptureTrace="{\"reason\":\""+reason+"\",\"samples\":"+samples+",\"loadingSamples\":"+loading+",\"missingSamples\":"+missing+",\"elapsedMs\":"+elapsed+"}";
    return result;
  }
  private static FocusSample LegacyFocus(IntPtr window,uint owner,string runtime,bool editable,bool secure,bool loading,bool identityValid) {
    if(!identityValid) {
      // A loading document can temporarily vend an obsolete renderer HWND.
      // Keep only a retry signal. Never expose its unverified field identity,
      // and never turn a mismatched editable/readonly/password leaf into one.
      return loading&&!editable&&!secure?Snapshot(window,owner,"",false,false,true):null;
    }
    return Snapshot(window,owner,runtime,editable,secure,loading);
  }
  private static FocusSample CaptureReady(Func<FocusSample> read,Func<bool> sameWindow,Func<long> elapsed,Action pause) {
    bool waiting=false;string firstEditor=null;int stable=0,samples=0,loading=0,missing=0;
    for(int sample=0;sample<80;sample++) {
      if(elapsed()>=2500)return CaptureResult(null,"deadline",samples,loading,missing,elapsed());
      if(!sameWindow())return CaptureResult(null,"host-changed",samples,loading,missing,elapsed());
      var actual=read();samples++;
      if(elapsed()>=2500)return CaptureResult(null,"query-deadline",samples,loading,missing,elapsed());
      if(!sameWindow())return CaptureResult(null,"host-changed-during-query",samples,loading,missing,elapsed());
      if(actual==null) {
        missing++;stable=0;
        if(!waiting)return CaptureResult(null,"missing-before-loading",samples,loading,missing,elapsed());
        // A provider may briefly disappear while replacing its loading tree.
        // No identity is inferred; resolve the same current host afresh.
      }
      else if(actual.Loading) {waiting=true;stable=0;loading++;}
      else if(!waiting)return CaptureResult(actual,"warm",samples,loading,missing,elapsed());
      else {
        if(!actual.Editable||actual.Secure)return CaptureResult(actual,actual.Secure?"secure":"noneditable",samples,loading,missing,elapsed());
        if(firstEditor==null)firstEditor=actual.Runtime;
        else if(firstEditor!=actual.Runtime)return CaptureResult(null,"editor-changed",samples,loading,missing,elapsed());
        if(++stable>=2)return CaptureResult(actual,"stable-editor",samples,loading,missing,elapsed());
      }
      pause();
    }
    return CaptureResult(null,"sample-limit",samples,loading,missing,elapsed());
  }
  public static string CaptureFocus() {
    var window=GetForegroundWindow();uint owner;GetWindowThreadProcessId(window,out owner);
    if(window==IntPtr.Zero||owner==0)return null;
    var clock=System.Diagnostics.Stopwatch.StartNew();
    Func<bool> same=delegate {uint currentOwner;var current=GetForegroundWindow();GetWindowThreadProcessId(current,out currentOwner);return current==window&&currentOwner==owner&&IsWindow(window);};
    var result=CaptureReady(delegate {try{var value=DescribeFocus(AutomationElement.FocusedElement,false);return value!=null&&value.Window==window&&value.Owner==owner?value:null;}catch(Exception){return null;}},same,delegate{return clock.ElapsedMilliseconds;},delegate{System.Threading.Thread.Sleep(30);});
    return result==null?null:result.Json;
  }
  private static bool MayResolveLegacy(bool editable,bool enabled,bool secure,bool readOnly) {return !editable&&enabled&&!secure&&!readOnly;}
  private static bool IA2Editable(uint state,int states) {return (state&4)!=0&&(states&8)!=0&&(states&4)==0&&(state&0x20000041)==0;}
  private static int CapturePolicyChecks() {
    int checks=0;Action<bool,string> check=delegate(bool ok,string label){if(!ok)throw new InvalidOperationException("Capture readiness regression: "+label);checks++;};
    check(LoadingDocument(15,0x844,0x400),"busy Chromium document");
    check(!LoadingDocument(15,0x840,0x400),"unfocused busy document");
    check(!LoadingDocument(42,0x844,0x400),"readonly text is not a loading document");
    check(!LoadingDocument(15,0x44,0x400),"ordinary readonly document");
    check(!LoadingDocument(15,0x844|1,0x400),"disabled document");
    check(!LoadingDocument(15,0x844|0x20000000,0x400),"protected document");
    check(!LoadingDocument(15,0x844,0x404),"defunct document");
    check(!LoadingDocument(15,0x844,0x408),"contradictory readonly editable document");
    var busy=Snapshot(new IntPtr(1),2,"document",false,false,true);
    var first=Snapshot(new IntPtr(1),2,"editor-a",true,false);
    var second=Snapshot(new IntPtr(1),2,"editor-b",true,false);
    var readOnly=Snapshot(new IntPtr(1),2,"readonly",false,false);
    var secure=Snapshot(new IntPtr(1),2,"password",false,true);
    var unverifiedLoading=LegacyFocus(new IntPtr(1),2,"unverified",false,false,true,false);
    check(unverifiedLoading!=null&&unverifiedLoading.Loading&&!unverifiedLoading.Editable&&!unverifiedLoading.Secure&&unverifiedLoading.Runtime=="","mismatched loading identity is retry metadata only");
    check(LegacyFocus(new IntPtr(1),2,"wrong-editor",true,false,false,false)==null,"mismatched positive identity is rejected");
    check(LegacyFocus(new IntPtr(1),2,"wrong-readonly",false,false,false,false)==null,"mismatched readonly identity is rejected");
    check(LegacyFocus(new IntPtr(1),2,"wrong-password",false,true,true,false)==null,"mismatched secure identity is never loading metadata");
    long elapsed=0;int reads=0;
    Func<FocusSample[],FocusSample> sequence=delegate(FocusSample[] values){elapsed=0;reads=0;return CaptureReady(delegate{return values[Math.Min(reads++,values.Length-1)];},delegate{return true;},delegate{return elapsed;},delegate{elapsed+=30;});};
    check(sequence(new[]{busy,busy,first,first})==first&&reads==4,"busy tree resolves to stable editor");
    check(sequence(new[]{unverifiedLoading,first,first})==first&&reads==3,"unverified loading must resolve to two verified editor samples");
    check(sequence(new FocusSample[]{null})==null&&reads==1,"initial unknown capture is rejected immediately");
    check(sequence(new[]{first})==first&&reads==1,"warm capture stays immediate");
    check(sequence(new[]{readOnly})==readOnly&&reads==1,"readonly leaf stays immediate");
    check(sequence(new[]{secure})==secure&&reads==1,"password leaf stays immediate");
    check(sequence(new[]{busy,readOnly})==readOnly&&reads==2,"loading cannot override readonly leaf");
    check(sequence(new[]{busy,secure})==secure&&reads==2,"loading cannot override password leaf");
    check(sequence(new[]{busy,first,second})==null&&reads==3,"first positive field stays latched");
    check(sequence(new[]{busy,first,busy,first,first})==first,"intervening loading retains first identity");
    check(sequence(new[]{busy})==null&&reads==80,"sample cap rejects permanent loading");
    check(sequence(new FocusSample[]{busy,null,first,first})==first&&reads==4,"transient missing provider after loading retries the same field");
    check(sequence(new FocusSample[]{busy,first,null,second,second})==null&&reads==4,"missing provider never forgets first positive identity");
    check(sequence(new FocusSample[]{busy,null})==null&&reads==80,"permanent missing provider remains bounded and ineligible");
    elapsed=0;reads=0;
    check(CaptureReady(delegate{reads++;elapsed+=2600;return first;},delegate{return true;},delegate{return elapsed;},delegate{})==null&&reads==1,"query time counts toward deadline");
    elapsed=0;reads=0;
    check(CaptureReady(delegate{reads++;return busy;},delegate{return reads==0;},delegate{return elapsed;},delegate{elapsed+=30;})==null&&reads==1,"foreground change during query cancels");
    elapsed=0;reads=0;
    check(CaptureReady(delegate{reads++;return reads==1?busy:null;},delegate{return reads<2;},delegate{return elapsed;},delegate{elapsed+=30;})==null&&reads==2,"host change during missing-provider retry cancels");
    reads=0;
    check(CaptureReady(delegate{reads++;return first;},delegate{return false;},delegate{return 0;},delegate{})==null&&reads==0,"changed window never queried");
    return checks;
  }
  public static string FocusPolicySelfTest() {
    if(!IA2Editable(4,8)||IA2Editable(4|0x40,8)||IA2Editable(4|0x20000000,8)||IA2Editable(4|1,8)||IA2Editable(4,8|4)||IA2Editable(0,8)||IA2Editable(4,0))throw new InvalidOperationException("IA2 focus policy regression");
    if(!MayResolveLegacy(false,true,false,false)||MayResolveLegacy(true,true,false,false)||MayResolveLegacy(false,false,false,false)||MayResolveLegacy(false,true,true,false)||MayResolveLegacy(false,true,false,true))throw new InvalidOperationException("Known UIA rejection was overridden");
    return "{\"ok\":true,\"passed\":12,\"capturePassed\":"+CapturePolicyChecks()+"}";
  }
  private static FocusSample ResolveMSAA(IntPtr window,uint owner,out string diagnostic) {
    diagnostic="{\"stage\":\"unavailable\"}";
    try {
      if(window==IntPtr.Zero||GetForegroundWindow()!=window)return null;
      uint actualOwner;uint thread=GetWindowThreadProcessId(window,out actualOwner);if(actualOwner!=owner)return null;
      var gui=new GUITHREADINFO();gui.size=Marshal.SizeOf(typeof(GUITHREADINFO));var focusedWindow=window;
      if(GetGUIThreadInfo(thread,ref gui)&&gui.focus!=IntPtr.Zero&&GetAncestor(gui.focus,2)==window)focusedWindow=gui.focus;
      uint focusOwner;GetWindowThreadProcessId(focusedWindow,out focusOwner);if(focusOwner!=owner)return null;
      Guid accessibleId=new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");Accessibility.IAccessible accessible;
      if(AccessibleObjectFromWindow(focusedWindow,0xFFFFFFFC,ref accessibleId,out accessible)<0||accessible==null)return null;
      var visited=new System.Collections.Generic.HashSet<long>();int depth;
      for(depth=0;depth<12;depth++) {
        IntPtr identity=Marshal.GetIUnknownForObject(accessible);long identityNumber=identity.ToInt64();Marshal.Release(identity);
        if(!visited.Add(identityNumber)){diagnostic="{\"stage\":\"focus-cycle\"}";return null;}
        uint flags=Convert.ToUInt32(accessible.get_accState(0));
        // Disabled/protected focus proxies cannot expose an eligible descendant.
        if((flags&0x20000001)!=0){diagnostic="{\"stage\":\"blocked-focus-chain\",\"state\":"+flags+"}";return Snapshot(window,owner,"99."+window.ToInt64()+".0",false,(flags&0x20000000)!=0);}
        object focus=accessible.accFocus;var next=focus as Accessibility.IAccessible;
        if(next!=null){
          IntPtr nextIdentity=Marshal.GetIUnknownForObject(next);bool self=nextIdentity.ToInt64()==identityNumber;Marshal.Release(nextIdentity);
          if(self)break;accessible=next;continue;
        }
        if(focus is int&&(int)focus!=0){next=accessible.get_accChild(focus) as Accessibility.IAccessible;if(next==null){diagnostic="{\"stage\":\"unresolved-focused-child\"}";return null;}accessible=next;continue;}
        break;
      }
      if(depth>=12){diagnostic="{\"stage\":\"focus-depth\"}";return null;}
      uint state=Convert.ToUInt32(accessible.get_accState(0));int role=Convert.ToInt32(accessible.get_accRole(0));
      diagnostic="{\"stage\":\"focused-msaa\",\"depth\":"+depth+",\"role\":"+role+",\"state\":"+state+",\"nativeFocusWindow\":\""+focusedWindow.ToInt64()+"\"}";
      if((state&4)==0)return null;
      var service=accessible as IAccessibleServiceProvider;if(service==null){diagnostic="{\"stage\":\"no-ia2-service\",\"role\":"+role+",\"state\":"+state+"}";return null;}
      Guid ia2Id=new Guid("E89F726E-C4F4-4C19-BB19-B647D7FA8478");IntPtr ia2=IntPtr.Zero;
      if(service.QueryService(ref accessibleId,ref ia2Id,out ia2)<0||ia2==IntPtr.Zero) {
        if(ia2!=IntPtr.Zero)Marshal.Release(ia2);ia2=IntPtr.Zero;Guid serviceId=ia2Id;
        if(service.QueryService(ref serviceId,ref ia2Id,out ia2)<0||ia2==IntPtr.Zero){if(ia2!=IntPtr.Zero)Marshal.Release(ia2);diagnostic="{\"stage\":\"ia2-query-unavailable\",\"role\":"+role+",\"state\":"+state+"}";return null;}
      }
      try {
        // IAccessible2 inherits the complete IUnknown/IDispatch/IAccessible ABI.
        // Slots35/41/42 are states/uniqueID/windowHandle in the published IDL:
        // https://github.com/LinuxA11y/IAccessible2/blob/master/api/Accessible2.idl
        int states,unique;IntPtr handle;
        if(IA2Number(ia2,35,out states)!=0||IA2Number(ia2,41,out unique)!=0||IA2Handle(ia2,out handle)!=0||unique==0){diagnostic="{\"stage\":\"ia2-identity-unavailable\"}";return null;}
        uint handleOwner;GetWindowThreadProcessId(handle,out handleOwner);
        bool identityValid=handle!=IntPtr.Zero&&GetAncestor(handle,2)==window&&handleOwner==owner;
        if(GetForegroundWindow()!=window){diagnostic="{\"stage\":\"foreground-changed\"}";return null;}
        bool secure=(state&0x20000000)!=0;
        // IA2_EDITABLE may coexist with MSAA_READONLY; explicit denial wins.
        bool editable=IA2Editable(state,states);
        diagnostic="{\"stage\":\""+(identityValid?"ia2-focus":"ia2-owner-mismatch")+"\",\"depth\":"+depth+",\"role\":"+role+",\"state\":"+state+",\"ia2States\":"+states+",\"uniqueId\":"+unique+",\"nativeFocusWindow\":\""+focusedWindow.ToInt64()+"\",\"window\":\""+handle.ToInt64()+"\"}";
        return LegacyFocus(window,owner,"99."+window.ToInt64()+"."+unique,editable,secure,LoadingDocument(role,state,states),identityValid);
      } finally {Marshal.Release(ia2);}
    }catch(Exception){diagnostic="{\"stage\":\"provider-unavailable\"}";return null;}
  }
  private static readonly object outputLock = new object();
  private static string lastFocus;
  private static AutomationFocusChangedEventHandler focusHandler;
  public static string FocusSnapshot() { var value=DescribeFocus(AutomationElement.FocusedElement,false);return value==null?null:value.Json; }
  public static string FocusDiagnostics() {
    var window=GetForegroundWindow();uint owner=0;GetWindowThreadProcessId(window,out owner);
    var element=AutomationElement.FocusedElement;var entries=new System.Collections.Generic.List<string>();
    // Capability metadata only: never Name, Value, text, selection or ranges.
    for(int depth=0;element!=null&&depth<5;depth++) {
      var current=element.Current;object value;bool hasValue=false,hasText=false;string valueReadOnly="null",textReadOnly="null";
      if(current.IsEnabled&&!current.IsPassword) {
        try { hasValue=element.TryGetCurrentPattern(ValuePattern.Pattern,out value);if(hasValue)valueReadOnly=((ValuePattern)value).Current.IsReadOnly?"true":"false"; } catch(Exception) {}
        try { hasText=element.TryGetCurrentPattern(TextPattern.Pattern,out value);if(hasText) { var readOnly=((TextPattern)value).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);if(readOnly is bool)textReadOnly=(bool)readOnly?"true":"false"; } } catch(Exception) {}
      }
      entries.Add("{\"processId\":"+current.ProcessId+",\"runtime\":\""+String.Join(".",element.GetRuntimeId())+"\",\"controlType\":"+current.ControlType.Id+",\"nativeHandle\":"+current.NativeWindowHandle+",\"enabled\":"+(current.IsEnabled?"true":"false")+",\"secure\":"+(current.IsPassword?"true":"false")+",\"keyboardFocusable\":"+(current.IsKeyboardFocusable?"true":"false")+",\"keyboardFocused\":"+(current.HasKeyboardFocus?"true":"false")+",\"valuePattern\":"+(hasValue?"true":"false")+",\"valueReadOnly\":"+valueReadOnly+",\"textPattern\":"+(hasText?"true":"false")+",\"textReadOnly\":"+textReadOnly+"}");
      try { element=TreeWalker.RawViewWalker.GetParent(element); } catch(Exception) { element=null; }
    }
    string msaa;ResolveMSAA(window,owner,out msaa);
    return "{\"ok\":true,\"handle\":\""+window.ToInt64()+"\",\"processId\":"+owner+",\"chain\":["+String.Join(",",entries)+"],\"msaa\":"+msaa+"}";
  }

  private static FocusSample DescribeFocus(AutomationElement element,bool fromEvent) {
    var window=GetForegroundWindow(); uint owner=0; GetWindowThreadProcessId(window,out owner);
    bool editable=false,secure=false,enabled=true,readOnly=false; string runtime="";
    if(element!=null) {
      var current=element.Current;secure=current.IsPassword;enabled=current.IsEnabled;
      runtime=String.Join(".",element.GetRuntimeId());
      if(fromEvent&&current.ProcessId!=owner)return null;
      object pattern;
      if(enabled&&!secure&&current.ProcessId==owner&&runtime.Length>0) {
        if(element.TryGetCurrentPattern(ValuePattern.Pattern,out pattern)) {readOnly=((ValuePattern)pattern).Current.IsReadOnly;editable=!readOnly;}
        else if(element.TryGetCurrentPattern(TextPattern.Pattern,out pattern)) {
          var value=((TextPattern)pattern).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
          if(value is bool){readOnly=(bool)value;editable=!readOnly;}
        }
      }
    }
    if(MayResolveLegacy(editable,enabled,secure,readOnly)) {
      string diagnostic;var legacy=ResolveMSAA(window,owner,out diagnostic);
      if(legacy!=null)return legacy;
    }
    return Snapshot(window,owner,runtime,editable,secure);
  }

  private static void EmitFocus(string snapshot) {
    if(snapshot==null)return;
    lock(outputLock) { if(lastFocus==snapshot)return;lastFocus=snapshot;Console.Out.WriteLine("{\"focus\":"+snapshot+"}");Console.Out.Flush(); }
  }
  public static void ObserveFocus() {
    focusHandler=delegate(object sender,AutomationFocusChangedEventArgs args) {
      try { var value=DescribeFocus(sender as AutomationElement,true);EmitFocus(value==null?null:value.Json); } catch(Exception) {}
    };
    Automation.AddAutomationFocusChangedEventHandler(focusHandler);
  }
  public static void EmitCurrentFocus() { try { EmitFocus(FocusSnapshot()); } catch(Exception) {} }
  public static void EmitSequence(uint sequence) { lock(outputLock) { Console.Out.WriteLine("{\"sequence\":"+sequence+"}");Console.Out.Flush(); } }
  public static void ObserveSequenceQueries() {
    var reader=new System.Threading.Thread(delegate() {
      try {
        string line;while((line=Console.In.ReadLine())!=null) {
          const string prefix="clipboard-sequence:";long id;
          if(!line.StartsWith(prefix,StringComparison.Ordinal)||!long.TryParse(line.Substring(prefix.Length),out id)||id<=0||id>9007199254740991L)continue;
          uint sequence=GetClipboardSequenceNumber();
          lock(outputLock) {Console.Out.WriteLine("{\"clipboardQuery\":"+id+",\"sequence\":"+sequence+"}");Console.Out.Flush();}
        }
      } catch(System.IO.IOException) {} catch(ObjectDisposedException) {}
    });reader.IsBackground=true;reader.Start();
  }
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
  [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion union; }
  [StructLayout(LayoutKind.Explicit)] public struct InputUnion { [FieldOffset(0)] public KEYBDINPUT keyboard; [FieldOffset(0)] public MOUSEINPUT mouse; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort key; public ushort scan; public uint flags; public uint time; public UIntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx,dy; public uint data,flags,time; public UIntPtr extra; }
  public static bool Paste(IntPtr expectedWindow,uint expectedOwner) {
    uint owner=0;var foreground=GetForegroundWindow();GetWindowThreadProcessId(foreground,out owner);
    if(foreground!=expectedWindow||owner!=expectedOwner)return false;
    INPUT[] events = new INPUT[4];
    events[0].type = 1; events[0].union.keyboard.key = 0x11;
    events[1].type = 1; events[1].union.keyboard.key = 0x56;
    events[2].type = 1; events[2].union.keyboard.key = 0x56; events[2].union.keyboard.flags = 2;
    events[3].type = 1; events[3].union.keyboard.key = 0x11; events[3].union.keyboard.flags = 2;
    return SendInput(4, events, Marshal.SizeOf(typeof(INPUT))) == 4;
  }
}
'@
function FocusInfo([bool]$WaitForLoading=$false) {
  $snapshot=if($WaitForLoading){[ClipBoardLineNative]::CaptureFocus()}else{[ClipBoardLineNative]::FocusSnapshot()}
  if (-not $snapshot) { throw 'The focused element changed while it was being inspected.' }
  return $snapshot | ConvertFrom-Json
}
function HeldShortcutKeys { @(0x11,0x12,0x10,0x0D,0x5B,0x5C) | Where-Object { [ClipBoardLineNative]::GetAsyncKeyState($_) -lt 0 } }
try {
  if ($Mode -ne 'CopyImages' -and $Mode -ne 'ClipboardSequence') {
    # PowerShell's dynamic caller can prevent UIA's one-time default proxy load.
    # Register Microsoft's strongly named Win32 providers before reading UIA.
    # https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/register-a-client-side-provider-assembly
    # UIA walks the first caller's ReflectedType; a PowerShell DynamicMethod
    # has none. A non-inlined compiled frame keeps that framework walk valid.
    [ClipBoardLineNative]::InitializeAutomation()
  }
  if ($Mode -eq 'CopyImages') {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($payload.files.Count -lt 1 -or $payload.files.Count -gt 1000) { throw 'Invalid image batch.' }
    foreach ($file in $payload.files) { if (-not [System.IO.File]::Exists($file) -or [System.IO.Path]::GetExtension($file) -ne '.png') { throw 'Managed image is unavailable.' } }
    $data = New-Object System.Windows.Forms.DataObject
    $data.SetData([System.Windows.Forms.DataFormats]::FileDrop, [string[]]$payload.files)
    $bitmap = [System.Drawing.Image]::FromFile($payload.files[0])
    $pngStream = [System.IO.MemoryStream]::new([System.IO.File]::ReadAllBytes($payload.files[0]))
    try {
      $data.SetImage($bitmap)
      # Preserve the exact full-resolution PNG (including alpha) for editors
      # that prefer PNG over the first-image Windows bitmap fallback.
      $data.SetData('PNG',$pngStream)
      if ($payload.text) { $data.SetText([string]$payload.text) }
      $markerStream = [System.IO.MemoryStream]::new([Convert]::FromBase64String($payload.marker))
      $data.SetData('ClipBoardLine.Internal.v1', $markerStream)
      [System.Windows.Forms.Clipboard]::SetDataObject($data,$true,5,100)
    } finally { $bitmap.Dispose();$pngStream.Dispose();if($markerStream){$markerStream.Dispose()} }
    @{ok=$true} | ConvertTo-Json -Compress
  } elseif ($Mode -eq 'ClipboardSequence') {
    @{ok=$true;sequence=[ClipBoardLineNative]::GetClipboardSequenceNumber()} | ConvertTo-Json -Compress
  } elseif ($Mode -eq 'Monitor') {
    [ClipBoardLineNative]::ObserveSequenceQueries()
    [ClipBoardLineNative]::ObserveFocus()
    $last = [uint32]0
    while ($true) {
      $sequence = [ClipBoardLineNative]::GetClipboardSequenceNumber()
      if ($sequence -ne $last) { [ClipBoardLineNative]::EmitSequence($sequence); $last=$sequence }
      [ClipBoardLineNative]::EmitCurrentFocus()
      Start-Sleep -Milliseconds 250
    }
  } elseif ($Mode -eq 'FocusPolicySelfTest') {
    [ClipBoardLineNative]::FocusPolicySelfTest()
  } elseif ($Mode -eq 'CaptureDiagnostics') {
    [ClipBoardLineNative]::FocusDiagnostics()
  } elseif ($Mode -eq 'Capture') {
    $captureInfo=FocusInfo -WaitForLoading $true
    $captureInfo | Add-Member -NotePropertyName captureTrace -NotePropertyValue ([ClipBoardLineNative]::CaptureTrace() | ConvertFrom-Json)
    $captureInfo | ConvertTo-Json -Compress
  } else {
    $phase=@{started=[DateTime]::UtcNow.ToString('o')}
    $expected = [Console]::In.ReadToEnd() | ConvertFrom-Json
    if ($expected.handle -notmatch '^\d+$' -or $expected.processId -le 0) { throw 'No previous application was captured.' }
    $window = [IntPtr][Int64]::Parse($expected.handle)
    [uint32]$owner = 0
    [void][ClipBoardLineNative]::GetWindowThreadProcessId($window,[ref]$owner)
    if (-not [ClipBoardLineNative]::IsWindow($window) -or $owner -ne $expected.processId) { throw 'The previous application has closed.' }
    [uint32]$frontOwner = 0
    $frontWindow=[ClipBoardLineNative]::GetForegroundWindow()
    [void][ClipBoardLineNative]::GetWindowThreadProcessId($frontWindow,[ref]$frontOwner)
    # Another top-level window in the same app is a different destination.
    # Never activate the captured HWND over that newer user choice.
    if ($frontWindow -ne $window -and $frontOwner -ne $expected.sourceProcessId) { throw 'Another window became active. Reopen the shelves from the intended field.' }
    if ($Mode -ne 'Restore' -and -not $expected.prepared) {
      # Keep the source focused until the invoking shortcut is fully released.
      # A held Enter must never start repeating inside the destination app.
      $releaseDeadline=[DateTime]::UtcNow.AddSeconds(2)
      $releasedSince=$null
      do {
        [uint32]$releaseOwner=0
        $releaseWindow=[ClipBoardLineNative]::GetForegroundWindow()
        [void][ClipBoardLineNative]::GetWindowThreadProcessId($releaseWindow,[ref]$releaseOwner)
        if ($releaseWindow -ne $window -and $releaseOwner -ne $expected.sourceProcessId) { throw 'Another window became active while the shortcut was held.' }
        $held=@(HeldShortcutKeys)
        if ($held.Count -eq 0) {
          if ($null -eq $releasedSince) { $releasedSince=[DateTime]::UtcNow }
          # Async key state changes before queued key messages are consumed.
          # Keep the source focused through a continuous release interval.
          if (([DateTime]::UtcNow-$releasedSince).TotalMilliseconds -ge 150) { break }
        } else { $releasedSince=$null }
        Start-Sleep -Milliseconds 30
      } while ([DateTime]::UtcNow -lt $releaseDeadline)
      if ($held.Count -gt 0 -or $null -eq $releasedSince -or ([DateTime]::UtcNow-$releasedSince).TotalMilliseconds -lt 150) { throw 'Release the shortcut keys, then try paste again.' }
      $phase.released=[DateTime]::UtcNow.ToString('o')
    }
    # A long key-release interval can outlive a closed/reused HWND or a
    # different foreground application. Check both again before activation.
    [uint32]$readyOwner=0
    [void][ClipBoardLineNative]::GetWindowThreadProcessId($window,[ref]$readyOwner)
    if (-not [ClipBoardLineNative]::IsWindow($window) -or $readyOwner -ne $expected.processId) { throw 'The previous application has closed.' }
    [uint32]$readyForeground=0
    $readyWindow=[ClipBoardLineNative]::GetForegroundWindow()
    [void][ClipBoardLineNative]::GetWindowThreadProcessId($readyWindow,[ref]$readyForeground)
    if ($readyWindow -ne $window -and $readyForeground -ne $expected.sourceProcessId) { throw 'Another window became active. No focus was changed.' }
    if ($Mode -in @('Paste','ValidatePaste') -and $expected.prepared) {
      if ([ClipBoardLineNative]::GetForegroundWindow() -ne $window) { throw 'Focus changed before paste. No keys were sent.' }
    } else {
      # SW_RESTORE also un-maximizes a maximized window; only restore minimized ones.
      if ([ClipBoardLineNative]::IsIconic($window)) { [void][ClipBoardLineNative]::ShowWindow($window,9) }
      [void][ClipBoardLineNative]::SetForegroundWindow($window)
    }
    $phase.activationRequested=[DateTime]::UtcNow.ToString('o')
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    $stable = 0
    do {
      Start-Sleep -Milliseconds 30
      $held = @(HeldShortcutKeys)
      if ([ClipBoardLineNative]::GetForegroundWindow() -ne $window) {
        [uint32]$currentOwner = 0
        [void][ClipBoardLineNative]::GetWindowThreadProcessId([ClipBoardLineNative]::GetForegroundWindow(),[ref]$currentOwner)
        if ($currentOwner -ne $expected.sourceProcessId) { throw 'Focus changed before paste. No keys were sent.' }
        $stable = 0
      } elseif ($Mode -eq 'Restore') { if ($held.Count -eq 0) { break } }
      else {
        $actual = FocusInfo
        if ($actual.processId -ne $expected.processId -or $actual.handle -ne $expected.handle -or $actual.secure -or ($actual.editable -and $actual.runtime -ne $expected.runtime)) { throw 'Focus changed. Select an editable field and reopen the shelves.' }
        if ($held.Count -eq 0 -and $expected.editable -and -not $expected.secure -and $actual.editable -and $actual.runtime -eq $expected.runtime) { $stable++ } else { $stable=0 }
      }
    } while ($stable -lt 2 -and [DateTime]::UtcNow -lt $deadline)
    if ([ClipBoardLineNative]::GetForegroundWindow() -ne $window -or $held.Count -gt 0) { throw 'Windows did not restore the intended field after the shortcut was released.' }
    if ($Mode -ne 'Restore' -and $stable -lt 2) { throw 'Focus changed. Select an editable field and reopen the shelves.' }
    $phase.targetStable=[DateTime]::UtcNow.ToString('o')
    if ($Mode -in @('Paste','ValidatePaste')) {
      $final=FocusInfo
      if (-not $final.editable -or $final.secure -or $final.processId -ne $expected.processId -or $final.handle -ne $expected.handle -or $final.runtime -ne $expected.runtime) { throw 'Focus changed immediately before paste. No keys were sent.' }
      if ($Mode -eq 'Paste') {
        if (-not [ClipBoardLineNative]::Paste($window,[uint32]$expected.processId)) { throw 'Windows blocked keyboard input or focus changed. Elevated applications may require manual paste.' }
        $phase.inputSent=[DateTime]::UtcNow.ToString('o')
      }
    }
    @{ok=$true;mode=$Mode;phase=$phase} | ConvertTo-Json -Compress
  }
} catch {
  $captureFailure=@{ok=$false;error=$_.Exception.Message}
  if($Mode -eq 'Capture'){$captureFailure.captureTrace=[ClipBoardLineNative]::CaptureTrace() | ConvertFrom-Json}
  $captureFailure | ConvertTo-Json -Compress; exit 1
}
