#!/usr/bin/env python3
"""Generate temple_os_swift/App/TempleOSMobile.xcodeproj/project.pbxproj.

Development-only. The project is small and hand-specified here so it stays
reviewable: one iOS app target (TempleOSMobile) depending on the local Swift
package ../TempleCore, the shared content from ../../shared as folder
references, and one UI test target (TempleOSMobileUITests).

Usage: gen_xcodeproj.py   (run from anywhere; paths are resolved from this file)

Device validation builds (docs/native-validation) install beside the normal app by overriding
TOS_BUNDLE_ID (app and UI test runner follow it) and enable the headless benchmark mode:
  xcodebuild ... TOS_BUNDLE_ID=io.github.templeosmobile.bench TOS_GIT_REV=$(git rev-parse --short HEAD) \
      SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) TEMPLEOS_BENCH'
"""
import os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP_DIR = os.path.join(ROOT, 'temple_os_swift', 'App')

ids = {}


def i(name):
    if name not in ids:
        ids[name] = 'A1B2C3D4' + ('%016X' % (len(ids) + 1))
    return ids[name]


SRCS = ['AppDelegate.swift', 'TempleView.swift', 'IOSShellEnv.swift', 'BenchMode.swift',
        # platform adapters (docs/ui-normalization/PLATFORM_UI_ABSTRACTION.md)
        'NativeKeyboardDiagnostics.swift', 'HardwareKeyAdapter.swift', 'AccessibilityAdapter.swift', 'DisplayContextAdapter.swift']
UITESTS = ['TempleOSMobileUITests.swift', 'DuoPostureUITests.swift']
SHARED = [('runtime', 'folder', '../../shared/runtime'), ('bundled-fs', 'folder', '../../shared/bundled-fs'),
          ('bundled-fs.index', 'text', '../../shared/bundled-fs.index'),
          ('catalog.json', 'text.json', '../../shared/program-manifests/catalog.json')]
RES = ['Assets.xcassets', 'PrivacyInfo.xcprivacy'] + [n for n, _, _ in SHARED]


def lst(keys, suffix=''):
    return '\n'.join(f'\t\t\t\t{i(k)} /* {k.split(".", 1)[1]}{suffix} */,' for k in keys)


def main():
    P = i('project'); MG = i('maingroup'); PG = i('products'); AG = i('appgroup'); RG = i('resgroup')
    APP = i('app.product'); T = i('target')
    pkg = i('pkgref'); dep = i('pkgdep'); depbf = i('pkgdep.bf')
    # Pure Swift mode: the generated translations of the bundled HolyC programs (TempleCore package, PureSwift product)
    dep2 = i('pkgdep.pureswift'); depbf2 = i('pkgdep.pureswift.bf')
    SB = i('sourcesphase'); RB = i('resphase'); FB = i('fwphase')
    PCL = i('projconflist'); TCL = i('targconflist')
    PD = i('projdebug'); PR = i('projrelease'); TD = i('targdebug'); TR = i('targrelease')
    UG = i('uitestgroup'); UPROD = i('uitest.product'); UT = i('uitesttarget'); USB = i('uitest.sources')
    UFB = i('uitest.frameworks'); UCL = i('uitest.conflist'); UD = i('uitest.debug'); UR = i('uitest.release')
    PROXY = i('uitest.proxy'); TDEP = i('uitest.targetdep')

    fr = []
    for s in SRCS:
        fr.append(f'\t\t{i("fr." + s)} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {s}; sourceTree = "<group>"; }};')
    for s in UITESTS:
        fr.append(f'\t\t{i("fr." + s)} /* {s} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {s}; sourceTree = "<group>"; }};')
    fr.append(f'\t\t{i("fr.Info.plist")} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
    fr.append(f'\t\t{i("fr.Assets.xcassets")} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
    fr.append(f'\t\t{i("fr.PrivacyInfo.xcprivacy")} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};')
    for n, t, p in SHARED:
        fr.append(f'\t\t{i("fr." + n)} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = {t}; name = "{n}"; path = "{p}"; sourceTree = SOURCE_ROOT; }};')
    fr.append(f'\t\t{APP} /* TempleOSMobile.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TempleOSMobile.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
    fr.append(f'\t\t{UPROD} /* TempleOSMobileUITests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = TempleOSMobileUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};')

    bf = []
    for s in SRCS + UITESTS:
        bf.append(f'\t\t{i("bf." + s)} /* {s} in Sources */ = {{isa = PBXBuildFile; fileRef = {i("fr." + s)} /* {s} */; }};')
    for n in RES:
        bf.append(f'\t\t{i("bf." + n)} /* {n} in Resources */ = {{isa = PBXBuildFile; fileRef = {i("fr." + n)} /* {n} */; }};')
    bf.append(f'\t\t{depbf} /* TempleCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep} /* TempleCore */; }};')
    bf.append(f'\t\t{depbf2} /* PureSwift in Frameworks */ = {{isa = PBXBuildFile; productRef = {dep2} /* PureSwift */; }};')

    common_proj = '''				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 16.0;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;'''
    common_targ = '''				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = TempleOSMobile/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = "$(TOS_BUNDLE_ID)";
				PRODUCT_NAME = "$(TARGET_NAME)";
				TOS_BUNDLE_ID = io.github.templeosmobile;
				TOS_GIT_REV = unknown;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				SUPPORTS_MACCATALYST = NO;
				TARGETED_DEVICE_FAMILY = "1,2";'''
    common_ui = '''				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				GENERATE_INFOPLIST_FILE = YES;
				MARKETING_VERSION = 1.0.0;
				PRODUCT_BUNDLE_IDENTIFIER = "$(TOS_BUNDLE_ID).uitests";
				PRODUCT_NAME = "$(TARGET_NAME)";
				TOS_BUNDLE_ID = io.github.templeosmobile;
				SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
				TARGETED_DEVICE_FAMILY = "1,2";
				TEST_TARGET_NAME = TempleOSMobile;'''

    txt = f'''// !$*UTF8*$!
// Generated by tools/xcode/gen_xcodeproj.py - edit the generator, not this file.
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 60;
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(bf)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		{PROXY} /* PBXContainerItemProxy */ = {{
			isa = PBXContainerItemProxy;
			containerPortal = {P} /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = {T};
			remoteInfo = TempleOSMobile;
		}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
{chr(10).join(fr)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{FB} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{depbf} /* TempleCore in Frameworks */,
				{depbf2} /* PureSwift in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{UFB} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{MG} = {{
			isa = PBXGroup;
			children = (
				{AG} /* TempleOSMobile */,
				{UG} /* TempleOSMobileUITests */,
				{RG} /* Shared */,
				{PG} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{PG} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{APP} /* TempleOSMobile.app */,
				{UPROD} /* TempleOSMobileUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
		{AG} /* TempleOSMobile */ = {{
			isa = PBXGroup;
			children = (
{lst(["fr." + s for s in SRCS] + ["fr.Info.plist", "fr.Assets.xcassets", "fr.PrivacyInfo.xcprivacy"])}
			);
			path = TempleOSMobile;
			sourceTree = "<group>";
		}};
		{UG} /* TempleOSMobileUITests */ = {{
			isa = PBXGroup;
			children = (
{lst(["fr." + s for s in UITESTS])}
			);
			path = TempleOSMobileUITests;
			sourceTree = "<group>";
		}};
		{RG} /* Shared */ = {{
			isa = PBXGroup;
			children = (
{lst(["fr." + n for n, _, _ in SHARED])}
			);
			name = Shared;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{T} /* TempleOSMobile */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {TCL} /* Build configuration list for PBXNativeTarget "TempleOSMobile" */;
			buildPhases = (
				AA0000000000000000000001 /* Input architecture guard */,
				{SB} /* Sources */,
				{FB} /* Frameworks */,
				{RB} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = TempleOSMobile;
			packageProductDependencies = (
				{dep} /* TempleCore */,
				{dep2} /* PureSwift */,
			);
			productName = TempleOSMobile;
			productReference = {APP} /* TempleOSMobile.app */;
			productType = "com.apple.product-type.application";
		}};
		{UT} /* TempleOSMobileUITests */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {UCL} /* Build configuration list for PBXNativeTarget "TempleOSMobileUITests" */;
			buildPhases = (
				{USB} /* Sources */,
				{UFB} /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				{TDEP} /* PBXTargetDependency */,
			);
			name = TempleOSMobileUITests;
			productName = TempleOSMobileUITests;
			productReference = {UPROD} /* TempleOSMobileUITests.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{P} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1600;
				LastUpgradeCheck = 1600;
				TargetAttributes = {{
					{UT} = {{
						TestTargetID = {T};
					}};
				}};
			}};
			buildConfigurationList = {PCL} /* Build configuration list for PBXProject "TempleOSMobile" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {MG};
			packageReferences = (
				{pkg} /* XCLocalSwiftPackageReference "../TempleCore" */,
			);
			productRefGroup = {PG} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{T} /* TempleOSMobile */,
				{UT} /* TempleOSMobileUITests */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{RB} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{lst(["bf." + n for n in RES], " in Resources")}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
\t\tAA0000000000000000000001 /* Input architecture guard */ = {{
\t\t\tisa = PBXShellScriptBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ();
\t\t\tinputPaths = ();
\t\t\toutputPaths = ();
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t\tshellPath = /bin/sh;
\t\t\tshellScript = "python3 \\\"$SRCROOT/../../tools/input-audit/check_input_architecture.py\\\" --platform ios\\n";
\t\t}};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{SB} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{lst(["bf." + s for s in SRCS], " in Sources")}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
		{USB} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{lst(["bf." + s for s in UITESTS], " in Sources")}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		{TDEP} /* PBXTargetDependency */ = {{
			isa = PBXTargetDependency;
			target = {T} /* TempleOSMobile */;
			targetProxy = {PROXY} /* PBXContainerItemProxy */;
		}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		{PD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_proj}
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{PR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_proj}
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{TD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_targ}
			}};
			name = Debug;
		}};
		{TR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_targ}
			}};
			name = Release;
		}};
		{UD} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_ui}
			}};
			name = Debug;
		}};
		{UR} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{common_ui}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{PCL} /* Build configuration list for PBXProject "TempleOSMobile" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{PD} /* Debug */,
				{PR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{TCL} /* Build configuration list for PBXNativeTarget "TempleOSMobile" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{TD} /* Debug */,
				{TR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{UCL} /* Build configuration list for PBXNativeTarget "TempleOSMobileUITests" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{UD} /* Debug */,
				{UR} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{pkg} /* XCLocalSwiftPackageReference "../TempleCore" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = ../TempleCore;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{dep} /* TempleCore */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = TempleCore;
		}};
		{dep2} /* PureSwift */ = {{
			isa = XCSwiftPackageProductDependency;
			productName = PureSwift;
		}};
/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {P} /* Project object */;
}}
'''
    proj = os.path.join(APP_DIR, 'TempleOSMobile.xcodeproj')
    os.makedirs(os.path.join(proj, 'xcshareddata', 'xcschemes'), exist_ok=True)
    open(os.path.join(proj, 'project.pbxproj'), 'w').write(txt)
    ref = lambda tid, prod, name: (f'<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{tid}" '
                                   f'BuildableName = "{prod}" BlueprintName = "{name}" ReferencedContainer = "container:TempleOSMobile.xcodeproj">'
                                   '</BuildableReference>')
    app_ref = ref(T, 'TempleOSMobile.app', 'TempleOSMobile')
    ui_ref = ref(UT, 'TempleOSMobileUITests.xctest', 'TempleOSMobileUITests')
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {app_ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            {ui_ref}
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "NO">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {app_ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
    open(os.path.join(proj, 'xcshareddata', 'xcschemes', 'TempleOSMobile.xcscheme'), 'w').write(scheme)
    print('wrote', proj)


if __name__ == '__main__':
    main()
