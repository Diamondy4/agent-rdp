# uia_com.ps1 - the COM (IUIAutomation) layer: walking, model data, actions
#
# Everything UI-Automation related goes through the COM API: the managed
# System.Windows.Automation wrapper is chatty (one cross-process call per property,
# ~3.3 ms per node) and its search APIs are unreliable next to the COM client.
#
# The walker is compiled in-process with Add-Type (the same mechanism the P/Invoke
# helpers use - no separate project, no build step, no extra binary). It runs on an
# MTA thread, returns plain managed data (no COM object escapes) and KEEPS the
# elements it visited, addressable by UiaNode.Id, so actions reach a node directly
# through the COM patterns instead of re-finding it by geometry. IIDs, vtable order,
# property ids and pattern ids come from UIAutomationClient.h (Windows SDK).

$script:ComWalkerAvailable = $null

# Verbose COM-layer diagnostics, enabled with AGENT_RDP_COM_DEBUG=1
$script:ComDebug = $env:AGENT_RDP_COM_DEBUG -eq '1'

function Write-ComDebug {
    param([string]$Message)

    if ($script:ComDebug) { Write-Log ("COM debug: " + $Message) "WARN" }
}

function Initialize-UiaComWalker {
    if ($null -ne $script:ComWalkerAvailable) { return $script:ComWalkerAvailable }

    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

public class UiaNode {
    public string Role;
    public string Name;
    public string AutomationId;
    public string ClassName;
    public double[] Bounds;
    public bool Enabled;
    public bool Focusable;
    public bool Focused;
    public bool Offscreen;
    public bool HasValue;
    public bool ValueReadOnly;
    public string Value;
    public bool HasToggle;
    public int ToggleState;
    public string[] Patterns = new string[0];
    public bool TextPattern;
    public int ChildIndex;
   public int ProcessId;
   public int WindowVisualState;
    public int Id;
    public int NativeWindowHandle;
    public List<UiaNode> Children = new List<UiaNode>();
}

public class UiaSnapshot {
    public UiaNode Root;
    public bool Truncated;
    public int NodeCount;
    public bool ProviderFailure;
    public int SkippedWindows;
}

public enum UiaTreeScope { None = 0, Element = 1, Children = 2, Descendants = 4, Parent = 8, Ancestors = 16, Subtree = 7 }
public enum UiaElementMode { None = 0, Full = 1 }

[ComImport, Guid("352ffba8-0973-437c-a61f-f64cafd81df9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationCondition { }

[ComImport, Guid("14314595-b4bc-4055-95f2-58f2e42c9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationElementArray {
    int Length { get; }
    IUIAutomationElement GetElement(int index);
}

[ComImport, Guid("b32a92b5-bc25-4078-9c08-d7ee95c48e03"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationCacheRequest {
    void AddProperty(int propertyId);
    void AddPattern(int patternId);
    IUIAutomationCacheRequest Clone();
    UiaTreeScope TreeScope { get; set; }
    IUIAutomationCondition TreeFilter { get; set; }
    UiaElementMode AutomationElementMode { get; set; }
}

[ComImport, Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationElement {
    void SetFocus();
    void GetRuntimeId();
    void FindFirst();
    IUIAutomationElementArray FindAll(UiaTreeScope scope, IUIAutomationCondition condition);
    void FindFirstBuildCache();
    IUIAutomationElementArray FindAllBuildCache(UiaTreeScope scope, IUIAutomationCondition condition, IUIAutomationCacheRequest cacheRequest);
    IUIAutomationElement BuildUpdatedCache(IUIAutomationCacheRequest cacheRequest);
    object GetCurrentPropertyValue(int propertyId);
    void GetCurrentPropertyValueEx();
    object GetCachedPropertyValue(int propertyId);
    void GetCachedPropertyValueEx();
    void GetCurrentPatternAs();
    void GetCachedPatternAs();
    // GetCurrentPattern returns a raw IUnknown*, not a VARIANT: without the
    // Interface marshaler the runtime reads the pointer as an invalid OLE variant.
    [return: MarshalAs(UnmanagedType.Interface)]
    object GetCurrentPattern(int patternId);
    void GetCachedPattern();
    void GetCachedParent();
    IUIAutomationElementArray GetCachedChildren();
}

[ComImport, Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomation {
    void CompareElements();
    void CompareRuntimeIds();
    IUIAutomationElement GetRootElement();
    void ElementFromHandle();
    void ElementFromPoint();
    void GetFocusedElement();
    IUIAutomationElement GetRootElementBuildCache(IUIAutomationCacheRequest cacheRequest);
    void ElementFromHandleBuildCache();
    void ElementFromPointBuildCache();
    void GetFocusedElementBuildCache();
    void CreateTreeWalker();
    void get_ControlViewWalker();
    void get_ContentViewWalker();
    void get_RawViewWalker();
    void get_RawViewCondition();
    void get_ControlViewCondition();
    void get_ContentViewCondition();
    IUIAutomationCacheRequest CreateCacheRequest();
    IUIAutomationCondition CreateTrueCondition();
}

public enum UiaToggleState { Off = 0, On = 1, Indeterminate = 2 }
public enum UiaWindowVisualState { Normal = 0, Maximized = 1, Minimized = 2 }
public enum UiaScrollAmount { NoAmount = 0, SmallIncrement = 1, LargeIncrement = 2, SmallDecrement = 3, LargeDecrement = 4 }

[ComImport, Guid("a94cd8b1-0844-4cd6-9d2d-640537ab39e9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationValuePattern {
    void SetValue([MarshalAs(UnmanagedType.LPWStr)] string value);
    void get_CurrentValue();
    void get_CurrentIsReadOnly();
    void get_CachedValue();
    void get_CachedIsReadOnly();
}

[ComImport, Guid("94cf8058-9b8d-4ab9-8bfd-4cd0a33c8c70"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationTogglePattern {
    void Toggle();
    int get_CurrentToggleState();
    void get_CachedToggleState();
}

[ComImport, Guid("a8efa66a-0fda-421a-9194-38021f3578ea"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationSelectionItemPattern {
    void Select();
    void AddToSelection();
    void RemoveFromSelection();
    void get_CurrentIsSelected();
    void get_CurrentSelectionContainer();
    void get_CachedIsSelected();
    void get_CachedSelectionContainer();
}

[ComImport, Guid("619be086-1f4e-4ee4-bafa-210128738730"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationExpandCollapsePattern {
    void Expand();
    void Collapse();
    void get_CurrentExpandCollapseState();
    void get_CachedExpandCollapseState();
}

[ComImport, Guid("88f4d42a-e881-459d-a77c-73bbbb7e02dc"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationScrollPattern {
    void Scroll(UiaScrollAmount horizontalAmount, UiaScrollAmount verticalAmount);
    void SetScrollPercent(double horizontalPercent, double verticalPercent);
    void get_CurrentHorizontalScrollPercent();
    void get_CurrentVerticalScrollPercent();
    void get_CurrentHorizontalViewSize();
    void get_CurrentVerticalViewSize();
    void get_CurrentHorizontallyScrollable();
    void get_CurrentVerticallyScrollable();
    void get_CachedHorizontalScrollPercent();
    void get_CachedVerticalScrollPercent();
    void get_CachedHorizontalViewSize();
    void get_CachedVerticalViewSize();
    void get_CachedHorizontallyScrollable();
    void get_CachedVerticallyScrollable();
}

[ComImport, Guid("0faef453-9208-43ef-bbb2-3b485177864f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationWindowPattern {
    void Close();
    void WaitForInputIdle(int milliseconds);
    void SetWindowVisualState(UiaWindowVisualState state);
    void get_CurrentCanMaximize();
    void get_CurrentCanMinimize();
    void get_CurrentIsModal();
    void get_CurrentIsTopmost();
    void get_CurrentWindowVisualState();
    void get_CurrentWindowInteractionState();
}

[ComImport, Guid("b488300f-d015-4f19-9c29-bb595e3645ef"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IUIAutomationScrollItemPattern {
    void ScrollIntoView();
}

public static class UiaComWalker {
    private const int PidBoundingRectangle = 30001;
    private const int PidControlType = 30003;
    private const int PidProcessId = 30002;
    private const int PidName = 30005;
    private const int PidHasKeyboardFocus = 30008;
    private const int PidIsKeyboardFocusable = 30009;
    private const int PidIsEnabled = 30010;
    private const int PidAutomationId = 30011;
    private const int PidClassName = 30012;
    private const int PidIsOffscreen = 30022;
    private const int PidValueValue = 30045;
    private const int PidValueIsReadOnly = 30046;
    private const int PidIsExpandCollapseAvailable = 30028;
    private const int PidIsInvokeAvailable = 30031;
    private const int PidIsRangeValueAvailable = 30033;
    private const int PidIsScrollAvailable = 30034;
    private const int PidIsScrollItemAvailable = 30035;
    private const int PidIsSelectionItemAvailable = 30036;
    private const int PidIsSelectionAvailable = 30037;
    private const int PidIsTextAvailable = 30040;
    private const int PidIsToggleAvailable = 30041;
    private const int PidIsTransformAvailable = 30042;
    private const int PidIsValueAvailable = 30043;
    private const int PidIsWindowAvailable = 30044;
   private const int PidWindowVisualState = 30075;
    private const int PidNativeWindowHandle = 30020;
    private const int PidToggleToggleState = 30086;

    private static readonly int[] CachedProperties = new int[] {
        PidBoundingRectangle, PidControlType, PidName, PidHasKeyboardFocus, PidIsKeyboardFocusable,
        PidIsEnabled, PidAutomationId, PidClassName, PidIsOffscreen, PidValueValue, PidValueIsReadOnly,
        PidIsExpandCollapseAvailable, PidIsInvokeAvailable, PidIsRangeValueAvailable, PidIsScrollAvailable,
        PidIsScrollItemAvailable, PidIsSelectionItemAvailable, PidIsSelectionAvailable, PidIsTextAvailable,
        PidIsToggleAvailable, PidIsTransformAvailable, PidIsValueAvailable, PidIsWindowAvailable
        , PidProcessId, PidWindowVisualState, PidToggleToggleState
    };

    private static readonly Dictionary<int, string> ControlTypes = new Dictionary<int, string> {
        { 50000, "Button" }, { 50001, "Calendar" }, { 50002, "CheckBox" }, { 50003, "ComboBox" },
        { 50004, "Edit" }, { 50005, "Hyperlink" }, { 50006, "Image" }, { 50007, "ListItem" },
        { 50008, "List" }, { 50009, "Menu" }, { 50010, "MenuBar" }, { 50011, "MenuItem" },
        { 50012, "ProgressBar" }, { 50013, "RadioButton" }, { 50014, "ScrollBar" }, { 50015, "Slider" },
        { 50016, "Spinner" }, { 50017, "StatusBar" }, { 50018, "Tab" }, { 50019, "TabItem" },
        { 50020, "Text" }, { 50021, "ToolBar" }, { 50022, "ToolTip" }, { 50023, "Tree" },
        { 50024, "TreeItem" }, { 50025, "Custom" }, { 50026, "Group" }, { 50027, "Thumb" },
        { 50028, "DataGrid" }, { 50029, "DataItem" }, { 50030, "Document" }, { 50031, "SplitButton" },
        { 50032, "Window" }, { 50033, "Pane" }, { 50034, "Header" }, { 50035, "HeaderItem" },
        { 50036, "Table" }, { 50037, "TitleBar" }, { 50038, "Separator" }, { 50039, "SemanticZoom" },
        { 50040, "AppBar" }
    };

    // Elements of the most recent walk, addressable by UiaNode.Id, so actions reach a
    // node directly instead of re-finding it (no hit tests, no coordinate math).
    private static readonly List<IUIAutomationElement> Elements = new List<IUIAutomationElement>();
    private static readonly object ElementsLock = new object();
    private static int WalkEpoch = 0;

    private sealed class WalkState {
        public int MaxNodes;
        public int MaxDepth;
        public long MaxMilliseconds;
        public System.Diagnostics.Stopwatch Clock;
        public int NodeCount;
        public bool Truncated;
        public bool ProviderFailure;
        public int SkippedWindows;
        public bool PerWindow;
        public IUIAutomationCondition TrueCondition;
        public IUIAutomationCacheRequest SubtreeCache;
        public List<IUIAutomationElement> Elements;
    }

    public static UiaSnapshot Snapshot(int maxDepth, int maxNodes, int maxSeconds) {
        UiaSnapshot result = null;
        Exception failure = null;
        int epoch;

        lock (ElementsLock) { epoch = ++WalkEpoch; }

        // The cache builds inside the walk talk to every provider and none of it is
        // interruptible, so the walk gets a wall-clock bound of its own: past it the
        // agent answers with an error instead of holding every later request behind
        // a provider that will not answer.
        long budgetMs = (long)maxSeconds * 1000L + 3000L;

        Thread worker = new Thread(delegate() {
            try { result = SnapshotCore(maxDepth, maxNodes, maxSeconds, epoch); }
            catch (Exception ex) { failure = ex; }
        });
        worker.SetApartmentState(ApartmentState.MTA);
        worker.IsBackground = true;
        worker.Start();

        if (!worker.Join((int)budgetMs)) {
            throw new InvalidOperationException(
                "UI Automation COM walk did not finish within " + budgetMs + " ms; a provider is probably blocking the desktop (the partial walk was discarded)");
        }

        if (failure != null) {
            throw new InvalidOperationException("UI Automation COM walk failed: " + failure.Message, failure);
        }

        return result;
    }

    // Cached properties only. The cached pattern objects were never used - pattern
    // availability comes from the Is*PatternAvailable properties and actions call
    // GetCurrentPattern on the live element - while asking every provider for a
    // dozen pattern objects per node is the largest part of a cache build and
    // another way for the whole batch to fail.
    private static IUIAutomationCacheRequest CreateCacheRequest(IUIAutomation uia, UiaTreeScope scope) {
        IUIAutomationCacheRequest cache = uia.CreateCacheRequest();
        cache.TreeScope = scope;
        cache.AutomationElementMode = UiaElementMode.Full;
        foreach (int propertyId in CachedProperties) { cache.AddProperty(propertyId); }
        return cache;
    }

    private static UiaSnapshot SnapshotCore(int maxDepth, int maxNodes, int maxSeconds, int epoch) {
        Guid coclassId = new Guid("ff48dba4-60ef-4201-aa87-54103eef594e");
        IUIAutomation uia = (IUIAutomation)Activator.CreateInstance(Type.GetTypeFromCLSID(coclassId));

        IUIAutomationCacheRequest subtreeCache = CreateCacheRequest(uia, UiaTreeScope.Subtree);
        IUIAutomationElement desktop;
        bool perWindow = false;

        try {
            // Fast path: one Subtree-scoped cache for the whole desktop.
            desktop = uia.GetRootElementBuildCache(subtreeCache);
        } catch (Exception) {
            // A provider can fail the desktop-wide batch (observed on a live host:
            // the desktop root itself answered E_FAIL, so any build that includes
            // the element failed while a Children-scoped one worked). Cache each
            // top-level window on its own instead, so one broken provider costs
            // that window rather than every snapshot.
            perWindow = true;
            try {
                desktop = uia.GetRootElementBuildCache(CreateCacheRequest(uia, UiaTreeScope.Element | UiaTreeScope.Children));
            } catch (Exception) {
                desktop = uia.GetRootElement();
            }
        }

        WalkState state = new WalkState();
        state.MaxNodes = maxNodes;
        state.MaxDepth = maxDepth;
        state.MaxMilliseconds = (long)maxSeconds * 1000;
        state.Clock = System.Diagnostics.Stopwatch.StartNew();
        state.PerWindow = perWindow;
        state.TrueCondition = uia.CreateTrueCondition();
        state.SubtreeCache = subtreeCache;
        state.Elements = new List<IUIAutomationElement>();
        state.Elements.Add(null);   // ids are 1-based (UiaNode.Id == NodeCount)

        UiaSnapshot snapshot = new UiaSnapshot();
        snapshot.Root = BuildNode(desktop, 0, 0, state);
        snapshot.NodeCount = state.NodeCount;
        snapshot.Truncated = state.Truncated;
        snapshot.ProviderFailure = state.ProviderFailure;
        snapshot.SkippedWindows = state.SkippedWindows;

        // Publish only on completion: an abandoned (timed-out) walk must not
        // overwrite the element list of a newer one.
        lock (ElementsLock) {
            if (epoch == WalkEpoch) {
                Elements.Clear();
                Elements.AddRange(state.Elements);
            }
        }

        return snapshot;
    }

    private static UiaNode BuildNode(IUIAutomationElement element, int depth, int childIndex, WalkState state) {
        if (state.NodeCount >= state.MaxNodes) { state.Truncated = true; return null; }

        // Time budget: the walk self-limits by cost, so a pathological tree
        // returns a partial tree instead of blocking the agent.
        if ((state.NodeCount & 0x3F) == 0 && state.Clock.ElapsedMilliseconds > state.MaxMilliseconds) {
            state.Truncated = true;
            return null;
        }

        state.NodeCount++;
        UiaNode node = new UiaNode();
        node.ChildIndex = childIndex;

        object controlType = Prop(element, PidControlType);
        if (controlType is int) {
            string role = null;
            if (ControlTypes.TryGetValue((int)controlType, out role)) { node.Role = role; }
        }

        node.Name = Str(element, PidName);
        node.AutomationId = Str(element, PidAutomationId);
        node.ClassName = Str(element, PidClassName);
        node.Bounds = Rect(element);
        node.Enabled = Flag(element, PidIsEnabled);
        node.Focusable = Flag(element, PidIsKeyboardFocusable);
        node.Focused = Flag(element, PidHasKeyboardFocus);
        node.Offscreen = Flag(element, PidIsOffscreen);
        node.TextPattern = Flag(element, PidIsTextAvailable);
       node.ProcessId = IntValue(element, PidProcessId);
       node.WindowVisualState = IntValue(element, PidWindowVisualState);
        node.Id = state.NodeCount;
        node.NativeWindowHandle = IntValue(element, PidNativeWindowHandle);
        state.Elements.Add(element);
        node.Patterns = PatternsOf(element);

        node.HasValue = Flag(element, PidIsValueAvailable);
        if (node.HasValue) {
            node.Value = Str(element, PidValueValue);
            node.ValueReadOnly = Flag(element, PidValueIsReadOnly);
        }

        node.HasToggle = Flag(element, PidIsToggleAvailable);
        if (node.HasToggle) {
            node.ToggleState = IntValue(element, PidToggleToggleState);
        }

        if (depth < state.MaxDepth) {
            IUIAutomationElementArray children = null;
            try {
                // In the per-window fallback the desktop has no cache of its own,
                // so its children come from a live search.
                children = (state.PerWindow && depth == 0)
                    ? element.FindAll(UiaTreeScope.Children, state.TrueCondition)
                    : element.GetCachedChildren();
            } catch (Exception) {
                // A provider that throws for this element costs its own subtree,
                // not the whole walk; the snapshot reports what is missing.
                state.ProviderFailure = true;
                state.SkippedWindows++;
                children = null;
            }
            if (children != null) {
                int count = children.Length;
                for (int i = 0; i < count; i++) {
                    IUIAutomationElement child = null;
                    try { child = children.GetElement(i); } catch (Exception) { continue; }
                    if (child == null) { continue; }

                    if (state.PerWindow && depth == 0) {
                        // Cache this window on its own; a provider that fails here
                        // costs the window, not the desktop. One retry covers a
                        // provider that is rebuilding its tree while we ask.
                        IUIAutomationElement refreshed = null;
                        for (int attempt = 0; attempt < 2 && refreshed == null; attempt++) {
                            if (attempt > 0) { Thread.Sleep(250); }
                            try { refreshed = child.BuildUpdatedCache(state.SubtreeCache); } catch (Exception) { }
                        }

                        if (refreshed == null) {
                            state.ProviderFailure = true;
                            state.SkippedWindows++;
                            continue;
                        }

                        child = refreshed;
                    }

                    UiaNode childNode = BuildNode(child, depth + 1, i, state);
                    if (childNode == null) { break; }

                    node.Children.Add(childNode);
                }
            }
        }

        return node;
    }

    /// <summary>Run an action on an MTA thread (the walk's elements live there).</summary>
    private static void RunOnMta(Action action) {
        Exception failure = null;

        Thread worker = new Thread(delegate() {
            try { action(); }
            catch (Exception ex) { failure = ex; }
        });
        worker.SetApartmentState(ApartmentState.MTA);
        worker.IsBackground = true;
        worker.Start();
        worker.Join();

        if (failure != null) {
            throw new InvalidOperationException("UI Automation action failed: " + failure.Message, failure);
        }
    }

    private static void RunOnElement(int id, Action<IUIAutomationElement> action) {
        IUIAutomationElement element;

        lock (ElementsLock) {
            if (id <= 0 || id >= Elements.Count || Elements[id] == null) {
                throw new InvalidOperationException("Unknown element id " + id + "; take a snapshot first");
            }
            element = Elements[id];
        }

        RunOnMta(delegate() { action(element); });
    }

    // Pattern objects come back as IUnknown. Acquire them through this helper so
    // an element that lacks the pattern produces a clear error instead of a null
    // dereference or a bare interface-cast failure.
    private static TPattern AcquirePattern<TPattern>(IUIAutomationElement element, int patternId, string patternName) where TPattern : class {
        object pattern;

        try {
            pattern = element.GetCurrentPattern(patternId);
        } catch (Exception ex) {
            throw new InvalidOperationException("The element does not support the " + patternName + " pattern: " + ex.Message, ex);
        }

        TPattern typed = pattern as TPattern;
        if (typed == null) {
            throw new InvalidOperationException("The element does not support the " + patternName + " pattern");
        }

        return typed;
    }

    public static void FocusElement(int id) {
        RunOnElement(id, delegate(IUIAutomationElement el) { el.SetFocus(); });
    }

    public static void SetElementValue(int id, string text) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationValuePattern>(el, 10002, "Value").SetValue(text);
        });
    }

    public static void ClearElementValue(int id) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationValuePattern>(el, 10002, "Value").SetValue("");
        });
    }

    public static void ToggleElement(int id, int desiredState) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            IUIAutomationTogglePattern pattern = AcquirePattern<IUIAutomationTogglePattern>(el, 10015, "Toggle");
            if (desiredState < 0 || pattern.get_CurrentToggleState() != desiredState) { pattern.Toggle(); }
        });
    }

    public static void SelectElement(int id) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationSelectionItemPattern>(el, 10010, "SelectionItem").Select();
        });
    }

    public static void SetElementExpanded(int id, bool expand) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            IUIAutomationExpandCollapsePattern pattern = AcquirePattern<IUIAutomationExpandCollapsePattern>(el, 10005, "ExpandCollapse");
            if (expand) { pattern.Expand(); } else { pattern.Collapse(); }
        });
    }

    public static void ScrollElement(int id, string direction, int amount) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            IUIAutomationScrollPattern pattern = AcquirePattern<IUIAutomationScrollPattern>(el, 10004, "Scroll");
            UiaScrollAmount horizontal = UiaScrollAmount.NoAmount;
            UiaScrollAmount vertical = UiaScrollAmount.NoAmount;

            if (direction == "up") { vertical = UiaScrollAmount.SmallDecrement; }
            else if (direction == "down") { vertical = UiaScrollAmount.SmallIncrement; }
            else if (direction == "left") { horizontal = UiaScrollAmount.SmallDecrement; }
            else if (direction == "right") { horizontal = UiaScrollAmount.SmallIncrement; }

            int times = amount <= 0 ? 1 : amount;
            for (int i = 0; i < times; i++) { pattern.Scroll(horizontal, vertical); }
        });
    }

    public static void ScrollElementIntoView(int id) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationScrollItemPattern>(el, 10017, "ScrollItem").ScrollIntoView();
        });
    }

    public static void CloseElementWindow(int id) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationWindowPattern>(el, 10009, "Window").Close();
        });
    }

    public static void SetElementWindowState(int id, int state) {
        RunOnElement(id, delegate(IUIAutomationElement el) {
            AcquirePattern<IUIAutomationWindowPattern>(el, 10009, "Window").SetWindowVisualState((UiaWindowVisualState)state);
        });
    }

    private static object Prop(IUIAutomationElement element, int propertyId) {
        try { return element.GetCachedPropertyValue(propertyId); }
        catch (Exception) { }

        // An element without a cache (the plain-root fallback) answers live.
        try { return element.GetCurrentPropertyValue(propertyId); }
        catch (Exception) { return null; }
    }

    private static bool Flag(IUIAutomationElement element, int propertyId) {
        object value = Prop(element, propertyId);
        return (value is bool) && (bool)value;
    }

    private static int IntValue(IUIAutomationElement element, int propertyId) {
        object value = Prop(element, propertyId);
        if (value is int) { return (int)value; }
        return 0;
    }

    private static string Str(IUIAutomationElement element, int propertyId) {
        object value = Prop(element, propertyId);
        return value == null ? null : value.ToString();
    }

    private static double[] Rect(IUIAutomationElement element) {
        return Prop(element, PidBoundingRectangle) as double[];
    }

    private static string[] PatternsOf(IUIAutomationElement element) {
        List<string> patterns = new List<string>();
        if (Flag(element, PidIsInvokeAvailable)) { patterns.Add("invoke"); }
        if (Flag(element, PidIsSelectionAvailable)) { patterns.Add("selection"); }
        if (Flag(element, PidIsValueAvailable)) { patterns.Add("value"); }
        if (Flag(element, PidIsRangeValueAvailable)) { patterns.Add("rangevalue"); }
        if (Flag(element, PidIsScrollAvailable)) { patterns.Add("scroll"); }
        if (Flag(element, PidIsExpandCollapseAvailable)) { patterns.Add("expandcollapse"); }
        if (Flag(element, PidIsWindowAvailable)) { patterns.Add("window"); }
        if (Flag(element, PidIsSelectionItemAvailable)) { patterns.Add("selectionitem"); }
        if (Flag(element, PidIsTextAvailable)) { patterns.Add("text"); }
        if (Flag(element, PidIsToggleAvailable)) { patterns.Add("toggle"); }
        if (Flag(element, PidIsTransformAvailable)) { patterns.Add("transform"); }
        if (Flag(element, PidIsScrollItemAvailable)) { patterns.Add("scrollitem"); }
        return patterns.ToArray();
    }
}
'@ -ErrorAction Stop
        $script:ComWalkerAvailable = $true
        Write-Log "COM walker compiled" "INFO"
    } catch {
        Write-Log ("COM walker failed to compile: " + $_.Exception.Message) "ERROR"
        $script:ComWalkerAvailable = $false
    }

    return $script:ComWalkerAvailable
}

# Walk the accessibility tree. maxNodes and maxSeconds bound the walk: it
# self-limits by cost and reports truncated = true instead of running away.
function Get-UiaComSnapshot {
    param(
        [int]$MaxDepth = 40,
        [int]$MaxNodes = 20000,
        [int]$MaxSeconds = 6
    )

    # The walker type is compiled on first use; any command that walks the tree
    # goes through here, so this is the single place that ensures it exists.
    if (-not (Initialize-UiaComWalker)) {
        throw "The UI Automation COM walker is unavailable; see the agent log for the compile error"
    }

    return [UiaComWalker]::Snapshot($MaxDepth, $MaxNodes, $MaxSeconds)
}

# A walk plus the nodes the caller needs: nodes carry Id, which addresses the
# element the walk stored, so actions use the patterns instead of coordinates.
function Get-UiaModel {
    param([int]$MaxDepth = 40)

    return (Get-UiaComSnapshot -MaxDepth $MaxDepth -MaxNodes $script:MaxSnapshotNodes -MaxSeconds $script:MaxSnapshotSeconds).Root
}

# Bounds of a model node as plain integers, or null when they are unusable.
function Get-UiaNodeBounds {
    param($Node)

    if ($null -eq $Node.Bounds -or $Node.Bounds.Length -ne 4) { return $null }

    $x = [double]$Node.Bounds[0]
    $y = [double]$Node.Bounds[1]
    $w = [double]$Node.Bounds[2]
    $h = [double]$Node.Bounds[3]

    if ([double]::IsNaN($x) -or [double]::IsInfinity($x) -or
        [double]::IsNaN($y) -or [double]::IsInfinity($y) -or
        [double]::IsNaN($w) -or [double]::IsInfinity($w) -or
        [double]::IsNaN($h) -or [double]::IsInfinity($h)) { return $null }

    return @{ x = [int]$x; y = [int]$y; width = [int]$w; height = [int]$h }
}

# Centre of a node, used only for pointer actions (a click needs a position).
function Get-UiaNodeClickPoint {
    param($Node)

    $bounds = Get-UiaNodeBounds $Node
    if ($null -eq $bounds -or $bounds["width"] -le 0 -or $bounds["height"] -le 0) { return $null }

    return @{
        x = [int]($bounds["x"] + ($bounds["width"] / 2))
        y = [int]($bounds["y"] + ($bounds["height"] / 2))
    }
}

# State flags of a model node - the single place that decides what a state is.
function Get-UiaNodeStates {
    param($Node)

    $states = @()
    if ($Node.Enabled) { $states += "enabled" }
    if ($Node.Focusable) { $states += "focusable" }
    if ($Node.Focused) { $states += "focused" }
    if ($Node.Offscreen) { $states += "offscreen" }
    if ($Node.HasValue) {
        if ($Node.ValueReadOnly) { $states += "readonly" } else { $states += "editable" }
    }
    if ($Node.TextPattern) { $states += "multiline" }
    if ($Node.HasToggle) {
        if ($Node.ToggleState -eq 1) { $states += "checked" }
        elseif ($Node.ToggleState -eq 2) { $states += "mixed" }
        else { $states += "unchecked" }
    }

    return $states
}

# Find a node in a model by predicate: returns @{ Node = ...; Path = ... } or null.
function Find-UiaNodeInModel {
    param($Node, [scriptblock]$Match, [int[]]$Path)

    if (& $Match $Node) { return @{ Node = $Node; Path = $Path } }

    foreach ($child in $Node.Children) {
        $found = Find-UiaNodeInModel -Node $child -Match $Match -Path ($Path + $child.ChildIndex)
        if ($null -ne $found) { return $found }
    }

    return $null
}
