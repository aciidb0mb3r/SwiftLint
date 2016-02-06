//
//  Configuration.swift
//  SwiftLint
//
//  Created by JP Simard on 2015-08-23.
//  Copyright (c) 2015 Realm. All rights reserved.
//

import Foundation
import SourceKittenFramework

private let fileManager = NSFileManager.defaultManager()

public struct Configuration: Equatable {
    public static let fileName = ".swiftlint.yml"
    public let disabledRules: [String] // disabled_rules
    public let included: [String]      // included
    public let excluded: [String]      // excluded
    public let reporter: String        // reporter (xcode, json, csv, checkstyle)
    public let rules: [Rule]
    public let useNestedConfigs: Bool  // process nested configs, will default to false
    public var rootPath: String?       // the root path of the lint to search for nested configs
    private var configPath: String?    // if successfully load from a path

    public init?(disabledRules: [String] = [],
                 optInRules: [String] = [],
                 whitelistRules: [String] = [],
                 included: [String] = [],
                 excluded: [String] = [],
                 reporter: String = "xcode",
                 rules: [Rule] = Configuration.rulesFromDict(),
                 useNestedConfigs: Bool = false) {
        self.included = included
        self.excluded = excluded
        self.reporter = reporter
        self.useNestedConfigs = useNestedConfigs

        // Validate that all rule identifiers map to a defined rule
        let validRuleIdentifiers = Configuration.rulesFromDict().map {
            $0.dynamicType.description.identifier
        }

        let validDisabledRules = disabledRules.filter({ validRuleIdentifiers.contains($0)})
        let invalidRules = disabledRules.filter({ !validRuleIdentifiers.contains($0) })
        if !invalidRules.isEmpty {
            for invalidRule in invalidRules {
                queuedPrintError("config error: '\(invalidRule)' is not a valid rule identifier")
            }
            let listOfValidRuleIdentifiers = validRuleIdentifiers.joinWithSeparator("\n")
            queuedPrintError("Valid rule identifiers:\n\(listOfValidRuleIdentifiers)")
        }

        // Validate that rule identifiers aren't listed multiple times
        if Set(validDisabledRules).count != validDisabledRules.count {
            let duplicateRules = validDisabledRules.reduce([String: Int]()) { accu, element in
                var accu = accu
                accu[element] = accu[element]?.successor() ?? 1
                return accu
            }.filter { $0.1 > 1 }
            queuedPrintError(duplicateRules.map { rule in
                "config error: '\(rule.0)' is listed \(rule.1) times"
            }.joinWithSeparator("\n"))
            return nil
        }
        self.disabledRules = validDisabledRules

        // white_list rules take precendence over all else.
        if !whitelistRules.isEmpty {

            if !disabledRules.isEmpty || !optInRules.isEmpty {
                queuedPrintError("'disabled_rules' or 'opt_in_rules' cannot be used in " +
                    "combination with 'whitelist_rules'")
                return nil
            }

            self.rules = rules.filter { rule in
                let id = rule.dynamicType.description.identifier
                return whitelistRules.contains(id)
            }
        } else {
            self.rules = rules.filter { rule in
                let id = rule.dynamicType.description.identifier
                if validDisabledRules.contains(id) { return false }
                return optInRules.contains(id) || !(rule is OptInRule)
            }
        }
    }

    public init?(dict: [String: AnyObject]) {

        // Deprecation warning for "enabled_rules"
        if dict["enabled_rules"] != nil {
            queuedPrint("'enabled_rules' has been renamed to 'opt_in_rules' " +
                "and will be completely removed in a future release.")
        }

        // Use either new 'opt_in_rules' or deprecated 'enabled_rules' for now.
        let optInRules = dict["opt_in_rules"] as? [String] ??
            dict["enabled_rules"] as? [String] ?? []

        self.init(
            disabledRules: dict["disabled_rules"] as? [String] ?? [],
            optInRules: optInRules,
            whitelistRules: dict["whitelist_rules"] as? [String] ?? [],
            included: dict["included"] as? [String] ?? [],
            excluded: dict["excluded"] as? [String] ?? [],
            reporter: dict["reporter"] as? String ?? XcodeReporter.identifier,
            useNestedConfigs: dict["use_nested_configs"] as? Bool ?? false,
            rules: Configuration.rulesFromDict(dict)
        )
    }

    public init(path: String = ".swiftlint.yml", rootPath: String? = nil, optional: Bool = true,
                quiet: Bool = false) {
        let fullPath = (path as NSString).absolutePathRepresentation()
        let fail = { fatalError("Could not read configuration file at path '\(fullPath)'") }
        if path.isEmpty || !NSFileManager.defaultManager().fileExistsAtPath(fullPath) {
            if !optional { fail() }
            self.init()!
            return
        }
        do {
            let yamlContents = try NSString(contentsOfFile: fullPath,
                encoding: NSUTF8StringEncoding) as String
            let dict = try YamlParser.parse(yamlContents)
            if !quiet {
                queuedPrintError("Loading configuration from '\(path)'")
            }
            self.init(dict: dict)!
            configPath = fullPath
            return
        } catch {
            fail()
        }
        self.init()!
    }

    public static func rulesFromDict(dict: [String: AnyObject]? = nil,
                                     ruleList: RuleList = masterRuleList) -> [Rule] {
        var rules = [Rule]()
        for rule in ruleList.list.values {
            let identifier = rule.description.identifier
            if let ConfigurableRuleType = rule as? ConfigurableRule.Type,
               ruleConfig = dict?[identifier] {
                do {
                    let configuredRule = try ConfigurableRuleType.init(config: ruleConfig)
                    rules.append(configuredRule)
                } catch {
                    queuedPrintError("Invalid config for '\(identifier)'. Falling back to default.")
                    rules.append(rule.init())
                }
            } else {
                rules.append(rule.init())
            }
        }

        return rules
    }

    public func lintablePathsForPath(path: String,
                                     fileManager: NSFileManager = fileManager) -> [String] {
        let pathsForPath = included.isEmpty ? fileManager.filesToLintAtPath(path) : []
        let excludedPaths = excluded.flatMap(fileManager.filesToLintAtPath)
        let includedPaths = included.flatMap(fileManager.filesToLintAtPath)
        return (pathsForPath + includedPaths).filter({ !excludedPaths.contains($0) })
    }

    public func lintableFilesForPath(path: String) -> [File] {
        return lintablePathsForPath(path).flatMap { File(path: $0) }
    }

    public func configForFile(file: File) -> Configuration {
        if useNestedConfigs,
            let containingDir = (file.path as NSString?)?.stringByDeletingLastPathComponent {
            return configForPath(containingDir)
        }
        return self
    }
}

// MARK: - Nested Configurations Extension

public extension Configuration {
    func configForPath(path: String) -> Configuration {
        let path = path as NSString
        let configSearchPath = path.stringByAppendingPathComponent(Configuration.fileName)

        // If a config exists and it isn't us, load and merge the configs
        if configSearchPath != configPath &&
            NSFileManager.defaultManager().fileExistsAtPath(configSearchPath) {
            return merge(Configuration(path: configSearchPath, optional: false, quiet: true))
        }

        // If we are not at the root path, continue down the tree
        if path != rootPath && path != "/" {
            return configForPath(path.stringByDeletingLastPathComponent)
        }

        // If nothing else, return self
        return self
    }

    // Currently merge simply overrides the current configuration with the new configuration.
    // This requires that all config files be fully specified. In the future this will be changed
    // to do a more intelligent merge allowing for partial nested configs.
    func merge(config: Configuration) -> Configuration {
        return config
    }
}

// Mark - == Implementation

public func == (lhs: Configuration, rhs: Configuration) -> Bool {
    return (lhs.disabledRules == rhs.disabledRules) &&
           (lhs.excluded == rhs.excluded) &&
           (lhs.included == rhs.included) &&
           (lhs.reporter == rhs.reporter) &&
           (lhs.useNestedConfigs == rhs.useNestedConfigs) &&
           (lhs.configPath == rhs.configPath) &&
           (lhs.rootPath == lhs.rootPath) &&
           (lhs.rules == rhs.rules)
}
