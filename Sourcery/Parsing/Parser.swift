//
// Created by Krzysztof Zablocki on 11/09/2016.
// Copyright (c) 2016 Pixle. All rights reserved.
//

import Foundation
import SourceKittenFramework
import PathKit

private extension Variable {
    /// Source structure used by the parser
    var __underlyingSource: [String: SourceKitRepresentable] {
        return (__parserData as? [String: SourceKitRepresentable]) ?? [:]
    }
}

private extension Type {
    /// Source structure used by the parser
    var __underlyingSource: [String: SourceKitRepresentable] {
        return (__parserData as? [String: SourceKitRepresentable]) ?? [:]
    }

    /// sets underlying source
    func setSource(source: [String: SourceKitRepresentable]) {
        __parserData = source
    }
}

fileprivate enum SubstringIdentifier {
    case body
    case key
    case name
    case nameSuffix
    case keyPrefix

    func range(`for` source: [String: SourceKitRepresentable]) -> (offset: Int64, length: Int64)? {

        func extract(_ offset: SwiftDocKey, _ length: SwiftDocKey) -> (offset: Int64, length: Int64)? {
            if let offset = source[offset.rawValue] as? Int64, let length = source[length.rawValue] as? Int64 {
                return (offset, length)
            }
            return nil
        }

        switch self {
        case .body:
            return extract(.bodyOffset, .bodyLength)
        case .key:
            return extract(.offset, .length)
        case .name:
            return extract(.nameOffset, .nameLength)
        case .nameSuffix:
            if let name = SubstringIdentifier.name.range(for: source), let key = SubstringIdentifier.key.range(for: source) {
                let nameEnd = name.offset + name.length
                return (name.offset + name.length, key.offset + key.length - nameEnd)
            }
        case .keyPrefix:
            return SubstringIdentifier.key.range(for: source).flatMap { (offset: 0, length: $0.offset) }
        }

        return nil
    }
}

private typealias Annotations = [String: NSObject]
private enum AnnotationType {
    case begin(Annotations)
    case annotations(Annotations)
    case end
}

typealias ParserResult = (types: [Type], typealiases: [Typealias])

final class Parser {

    fileprivate struct Line {
        enum LineType {
            case comment
            case blockStart
            case blockEnd
            case other
        }
        let content: String
        let type: LineType
        let annotations: Annotations
    }

    let verbose: Bool
    private(set) var contents: String = ""
    fileprivate var lines = [Line]()
    private(set) var path: String? = nil
    fileprivate var logPrefix: String {
        return path.flatMap { "\($0): " } ?? ""
    }

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    /// Parses file under given path.
    ///
    /// - Parameters:
    ///   - path: Path to file.
    ///   - existingTypes: List of existing types to use for further parsing.
    /// - Returns: All types we could find.
    /// - Throws: parsing errors.
    public func parseFile(_ path: Path, existingTypes: ParserResult = ([], [])) throws -> ParserResult {
        self.path = path.string
        return parseContents(try path.read(.utf8), existingTypes: existingTypes)
    }

    /// Parses given file context.
    ///
    /// - Parameters:
    ///   - contents: Contents of the file.
    ///   - existingTypes: List of existing types to use for further parsing.
    /// - Returns: All types we could find.
    /// - Throws: parsing errors.
    public func parseContents(_ contents: String, existingTypes: ParserResult = ([], [])) -> ParserResult {
        guard !contents.hasPrefix(Sourcery.generationMarker) else {
            if verbose { print("\(logPrefix)Skipping source file because it was generated by Sourcery") }
            return existingTypes
        }

        self.contents = contents
        processLines()

        let file = File(contents: contents)
        let source = Structure(file: file).dictionary

        var processedGlobalTypes = [[String: SourceKitRepresentable]]()
        let types = parseTypes(source, existingTypes: existingTypes.types, processed: &processedGlobalTypes)
        var typealises = existingTypes.typealiases

        typealises += parseTypealiases(from: source, containingType: nil, processed: processedGlobalTypes)
        return (types, typealises)
    }

    private func processLines() {
        var annotationsBlock = Annotations()
        self.lines = contents.lines()
                .map { $0.content.trimmingCharacters(in: .whitespaces) }
                .map { line in
                    var annotations = Annotations()
                    let isComment = line.hasPrefix("//")
                    var type: Line.LineType = isComment ? .comment : .other
                    if isComment {
                        switch searchForAnnotations(commentLine: line) {
                        case let .begin(items):
                            type = .blockStart
                            items.forEach { annotationsBlock[$0.key] = $0.value }
                            break
                        case let .annotations(items):
                            items.forEach { annotations[$0.key] = $0.value }
                            break
                        case .end:
                            type = .blockEnd
                            annotationsBlock.removeAll()
                            break
                        }
                    }

                    annotationsBlock.forEach { annotation in
                        annotations[annotation.key] = annotation.value
                    }

                    return Line(content: line,
                            type: type,
                            annotations: annotations)
                }
    }

    internal func parseTypes(_ source: [String: SourceKitRepresentable], existingTypes: [Type] = [], processed: inout [[String: SourceKitRepresentable]]) -> [Type] {
        var types = existingTypes
        walkTypes(source: source, processed: &processed) { kind, name, access, inheritedTypes, source in
            let type: Type

            switch kind {
            case .protocol:
                type = Protocol(name: name, accessLevel: access, isExtension: false, inheritedTypes: inheritedTypes)
            case .class:
                type = Type(name: name, accessLevel: access, isExtension: false, inheritedTypes: inheritedTypes)
            case .extension:
                type = Type(name: name, accessLevel: access, isExtension: true, inheritedTypes: inheritedTypes)
            case .extensionClass:
                type = Type(name: name, accessLevel: access, isExtension: true, inheritedTypes: inheritedTypes)
            case .struct:
                type = Struct(name: name, accessLevel: access, isExtension: false, inheritedTypes: inheritedTypes)
            case .extensionStruct:
                type = Struct(name: name, accessLevel: access, isExtension: true, inheritedTypes: inheritedTypes)
            case .enum:
                type = Enum(name: name, accessLevel: access, isExtension: false, inheritedTypes: inheritedTypes)
            case .extensionEnum:
                type = Enum(name: name, accessLevel: access, isExtension: true, inheritedTypes: inheritedTypes)
            case .enumelement:
                return parseEnumCase(source)
            case .varInstance:
                return parseVariable(source)
            case .varStatic, .varClass:
                return parseVariable(source, isStatic: true)
            case .varLocal, .varParameter:
                //! Don't log local / param vars
                return nil
            default:
                //! Don't log functions
                if kind.rawValue.hasPrefix("source.lang.swift.decl.function") { return nil }

                if verbose { print("\(logPrefix)Unsupported entry \"\(access) \(kind) \(name)\"") }
                return nil
            }

            type.isGeneric = isGeneric(source: source)
            type.setSource(source: source)
            type.annotations = parseAnnotations(source)
            types.append(type)
            return type
        }
        return types
    }

    /// Walks all types in the source
    private func walkTypes(source: [String: SourceKitRepresentable], containingType: Any? = nil, processed: inout [[String: SourceKitRepresentable]], foundEntry: (SwiftDeclarationKind, String, AccessLevel, [String], [String: SourceKitRepresentable]) -> Any?) {
        if let substructures = source[SwiftDocKey.substructure.rawValue] as? [SourceKitRepresentable] {
            for substructure in substructures {
                if let source = substructure as? [String: SourceKitRepresentable] {
                    processed.append(source)
                    walkType(source: source, containingType: containingType, foundEntry: foundEntry)
                }
            }
        }
    }

    /// Walks single type in the source, recursively processing containing types
    private func walkType(source: [String: SourceKitRepresentable], containingType: Any? = nil, foundEntry: (SwiftDeclarationKind, String, AccessLevel, [String], [String: SourceKitRepresentable]) -> Any?) {
        var type = containingType

        let inheritedTypes = extractInheritedTypes(source: source)

        if let requirements = parseTypeRequirements(source) {
            type = foundEntry(requirements.kind, requirements.name, requirements.accessibility, inheritedTypes, source)
            if let type = type, let containingType = containingType {
                processContainedType(type, within: containingType)
            }
        }

        var processedInnerTypes = [[String: SourceKitRepresentable]]()
        walkTypes(source: source, containingType: type, processed: &processedInnerTypes, foundEntry: foundEntry)

        if let type = type as? Type {
            parseTypealiases(from: source, containingType: type, processed: processedInnerTypes)
                .forEach { type.typealiases[$0.aliasName] = $0 }
        }
    }

    private func processContainedType(_ type: Any, within containingType: Any) {
        ///! only Type can contain children
        guard let containingType = containingType as? Type else {
            return
        }

        switch (containingType, type) {
        case let (_, variable as Variable):
            containingType.variables += [variable]
            if !variable.isStatic {
                if let enumeration = containingType as? Enum,
                    let updatedRawType = parseEnumRawType(enumeration: enumeration, from: variable) {

                    enumeration.rawType = updatedRawType
                }
            }

        case let (_, childType as Type):
            containingType.containedTypes += [childType]
            childType.parent = containingType
        case let (enumeration as Enum, enumCase as Enum.Case):
            enumeration.cases += [enumCase]
        default:
            break
        }
    }

    /// Extends types with their corresponding extensions.
    ///
    /// - Parameter types: Types and extensions.
    /// - Returns: Just types.
    internal func uniqueTypes(_ parserResult: ParserResult) -> [Type] {
        var unique = [String: Type]()
        let types = parserResult.types
        let typealiases = parserResult.typealiases

        //! flatten typealiases by their full names
        var typealiasesByNames = [String: Typealias]()
        typealiases.forEach { typealiasesByNames[$0.name] = $0 }
        types.forEach { type in
            type.typealiases.forEach({ (_, alias) in
                typealiasesByNames[alias.name] = alias
            })
        }

        //! if a typealias leads to another typealias, follow through and replace with final type
        typealiasesByNames.forEach { _, alias in

            var aliasNamesToReplace = [alias.name]
            var finalAlias = alias
            while let targetAlias = typealiasesByNames[finalAlias.typeName] {
                aliasNamesToReplace.append(targetAlias.name)
                finalAlias = targetAlias
            }

            //! replace all keys
            aliasNamesToReplace.forEach { typealiasesByNames[$0] = finalAlias }
        }

        func typeName(for alias: String, containingType: Type? = nil) -> String? {

            // first try global typealiases
            if let name = typealiasesByNames[alias]?.typeName {
                return name
            }

            guard let containingType = containingType,
                  let possibleTypeName = typealiasesByNames["\(containingType.name).\(alias)"]?.typeName else {
                return nil
            }

            //check if typealias is for one of contained types
            let containedType = containingType
                .containedTypes
                .filter {
                    $0.name == "\(containingType.name).\(possibleTypeName)" ||
                        $0.name == possibleTypeName
                }
                .first

            return containedType?.name ?? possibleTypeName
        }

        types
            .filter { $0.isExtension == false}
            .forEach { unique[$0.name] = $0 }

        //replace extensions for type aliases with original types
        types
            .filter { $0.isExtension == true }
            .forEach { $0.localName = typeName(for: $0.name) ?? $0.localName }

        types.forEach { type in
            type.inheritedTypes = type.inheritedTypes.map { typeName(for: $0) ?? $0 }

            guard let current = unique[type.name] else {
                unique[type.name] = type

                let inheritanceClause = type.inheritedTypes.isEmpty ? "" :
                        ": \(type.inheritedTypes.joined(separator: ", "))"

                if verbose { print("\(logPrefix)Found \"extension \(type.name)\(inheritanceClause)\" of type for which we don't have original type definition information") }
                return
            }

            if current == type { return }

            current.extend(type)
            unique[type.name] = current
        }

        for (_, type) in unique {
            for variable in type.variables {
                if let actualTypeName = typeName(for: variable.unwrappedTypeName, containingType: type) {
                    variable.type = unique[actualTypeName]
                } else {
                    variable.type = unique[variable.unwrappedTypeName]
                }
            }
        }

        for (_, type) in unique {
            if let enumeration = type as? Enum, enumeration.rawType == nil {
                guard let rawTypeName = enumeration.inheritedTypes.first else { continue }
                if let rawTypeCandidate = unique[rawTypeName] {
                    if !(rawTypeCandidate is Protocol) {
                        enumeration.rawType = rawTypeCandidate.name
                    }
                } else {
                    enumeration.rawType = rawTypeName
                }
            }
        }

        return unique.values.filter {
            let isPrivate = AccessLevel(rawValue: $0.accessLevel) == .private || AccessLevel(rawValue: $0.accessLevel) == .fileprivate
            if isPrivate && self.verbose { print("Skipping \($0.kind) \($0.name) as it is private") }
            return !isPrivate
            }.sorted { $0.name < $1.name }
    }

}

// MARK: Details parsing
extension Parser {

    fileprivate func parseTypeRequirements(_ dict: [String: SourceKitRepresentable]) -> (name: String, kind: SwiftDeclarationKind, accessibility: AccessLevel)? {
        guard let kind = (dict[SwiftDocKey.kind.rawValue] as? String).flatMap({ SwiftDeclarationKind(rawValue: $0) }),
              let name = dict[SwiftDocKey.name.rawValue] as? String else { return nil }

        let accessibility = (dict["key.accessibility"] as? String).flatMap({ AccessLevel(rawValue: $0.replacingOccurrences(of: "source.lang.swift.accessibility.", with: "") ) }) ?? .none
        return (name, kind, accessibility)
    }

    internal func extractInheritedTypes(source: [String: SourceKitRepresentable]) -> [String] {
        return (source[SwiftDocKey.inheritedtypes.rawValue] as? [[String: SourceKitRepresentable]])?.flatMap { type in
            return type[SwiftDocKey.name.rawValue] as? String
        } ?? []
    }

    internal func parseVariable(_ source: [String: SourceKitRepresentable], isStatic: Bool = false) -> Variable? {
        guard let (name, _, accesibility) = parseTypeRequirements(source),
            accesibility != .private && accesibility != .fileprivate,
            let type = source[SwiftDocKey.typeName.rawValue] as? String else { return nil }

        var writeAccessibility = AccessLevel.none
        var computed = false

        //! if there is body it might be computed
        if let bodylength = source[SwiftDocKey.bodyLength.rawValue] as? Int64 {
            computed = bodylength > 0
        }

        //! but if there is a setter, then it's not computed for sure
        if let setter = source["key.setter_accessibility"] as? String {
            writeAccessibility = AccessLevel(rawValue: setter.replacingOccurrences(of: "source.lang.swift.accessibility.", with: "")) ?? .none
            computed = false
        }

        let variable = Variable(name: name, typeName: type, accessLevel: (read: accesibility, write: writeAccessibility), isComputed: computed, isStatic: isStatic)
        variable.annotations = parseAnnotations(source)
        variable.__parserData = source

        return variable
    }

    fileprivate func parseEnumCase(_ source: [String: SourceKitRepresentable]) -> Enum.Case? {
        guard let (name, _, _) = parseTypeRequirements(source) else { return nil }

        var associatedValues: [Enum.Case.AssociatedValue] = []
        var rawValue: String? = nil

        if let wrappedBody = extract(.nameSuffix, from: source)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            switch (wrappedBody.characters.first, wrappedBody.characters.last) {
            case ("="?, _):
                let body = wrappedBody.substring(from: wrappedBody.index(after: wrappedBody.startIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                rawValue = parseEnumValues(body)
            case ("("?, ")"?):
                let body = wrappedBody.substring(with: wrappedBody.index(after: wrappedBody.startIndex)..<wrappedBody.index(before: wrappedBody.endIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
                associatedValues = parseEnumAssociatedValues(body)
            default:
                print("\(logPrefix)parseEnumCase: Unknown enum case body format \(wrappedBody)")
            }
        }

        let annotations = parseAnnotations(source)
        return Enum.Case(name: name, rawValue: rawValue, associatedValues: associatedValues, annotations: annotations)
    }

    fileprivate func parseEnumValues(_ body: String) -> String {
        /// = value
        let body = body.replacingOccurrences(of: "\"", with: "")
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate func parseEnumAssociatedValues(_ body: String) -> [Enum.Case.AssociatedValue] {
        guard !body.isEmpty else { return [] }

        /// name: type, otherType
        let components = body.components(separatedBy: ",")
        return components.flatMap { element in
            let nameType = element.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

            switch nameType.count {
            case 1:
                return Enum.Case.AssociatedValue(name: nil, typeName: nameType.first ?? "")
            case 2:
                return Enum.Case.AssociatedValue(name: nameType.first, typeName: nameType.last ?? "")
            default:
                print("\(logPrefix)parseEnumAssociatedValues: Unknown enum case body format \(body)")
                return nil
            }
        }
    }

    fileprivate func parseEnumRawType(enumeration: Enum, from variable: Variable) -> String? {
        guard variable.name == "rawValue" else {
            return nil
        }

        if variable.typeName == "RawValue" {
            return parseEnumRawValueAssociatedType(enumeration.__underlyingSource)
        }

        return variable.typeName
    }

    fileprivate func parseEnumRawValueAssociatedType(_ source: [String: SourceKitRepresentable]) -> String? {
        var rawType: String?

        extract(.body, from: source)?
            .replacingOccurrences(of: ";", with: "\n")
            .enumerateLines(invoking: { (substring, stop) in
                let substring = substring.trimmingCharacters(in: .whitespacesAndNewlines)

                if substring.hasPrefix("typealias"), let type = substring.components(separatedBy: " ").last {
                    rawType = type
                    stop = true
                }
            })

        return rawType
    }

    fileprivate func parseAnnotations(_ source: [String: SourceKitRepresentable]) -> Annotations {
        guard let range = SubstringIdentifier.key.range(for: source),
        let lineInfo = contents.lineAndCharacter(forByteOffset: Int(range.offset)) else { return [:] }

        var annotations = Annotations()
        for line in lines[0..<lineInfo.line-1].reversed() {
            line.annotations.forEach { annotation in
                annotations[annotation.key] = annotation.value
            }

            if line.type != .comment {
                break
            }
        }

        return annotations
    }

    fileprivate func searchForAnnotations(commentLine: String) -> AnnotationType {
        guard commentLine.contains("sourcery:") else { return .annotations([:]) }

        let substringRange: Range<String.CharacterView.Index>?
        let insideBlock: Bool
        if commentLine.contains("sourcery:begin:") {
            substringRange = commentLine
                    .range(of: "sourcery:begin:")
            insideBlock = true
        } else if commentLine.contains("sourcery:end") {
            return .end
        } else {
            substringRange = commentLine
                    .range(of: "sourcery:")
            insideBlock = false
        }

        guard let range = substringRange else { return .annotations([:]) }

        let annotationDefinitions = commentLine
                .substring(from: range.upperBound)
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        var annotations = Annotations()
        annotationDefinitions.forEach { annotation in
            let parts = annotation.components(separatedBy: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if let name = parts.first, !name.isEmpty {

                guard parts.count > 1, var value = parts.last, value.isEmpty == false else {
                    annotations[name] = NSNumber(value: true)
                    return
                }

                if let number = Float(value) {
                    annotations[name] = NSNumber(value: number)
                } else {
                    if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                        value = value[value.characters.index(after: value.startIndex) ..< value.characters.index(before: value.endIndex)]
                    }
                    annotations[name] = value as NSString
                }
            }
        }

        return insideBlock ? .begin(annotations) : .annotations(annotations)
    }

    fileprivate func parseTypealiases(from source: [String: SourceKitRepresentable], containingType: Type?, processed: [[String: SourceKitRepresentable]]) -> [Typealias] {
        var contentToParse = self.contents

        // replace all processed substructures with whitespaces so that we don't process their typealiases again
        for substructure in processed {
            if let substring = extract(.key, from: substructure) {

                let replacementCharacter = " "
                let count = substring.lengthOfBytes(using: .utf8) / replacementCharacter.lengthOfBytes(using: .utf8)
                let replacement = String(repeating: replacementCharacter, count: count)
                contentToParse = contentToParse.bridge().replacingOccurrences(of: substring, with: replacement)
            }
        }

        guard containingType != nil else {
            return parseTypealiases(SyntaxMap(file: File(contents: contentToParse)).tokens, contents: contentToParse)
        }

        if let body = extract(.body, from: source, contents: contentToParse) {
            return parseTypealiases(SyntaxMap(file: File(contents: body)).tokens, contents: body)
        } else {
            return []
        }
    }

    private func parseTypealiases(_ tokens: [SyntaxToken], contents: String, existingTypealiases: [Typealias] = []) -> [Typealias] {
        var typealiases = existingTypealiases

        for (index, token) in tokens.enumerated() {
            guard token.type == "source.lang.swift.syntaxtype.keyword",
                extract(token, contents: contents) == "typealias" else {
                    continue
            }

            if index > 0,
                let accessLevel = extract(tokens[index - 1], contents: contents).flatMap(AccessLevel.init),
                accessLevel == .private || accessLevel == .fileprivate {
                continue
            }

            guard let alias = extract(tokens[index + 1], contents: contents),
                let type = extract(tokens[index + 2], contents: contents) else {
                    continue
            }

            //get all subsequent type identifiers
            var subtypes = [type]
            var index = index + 2
            while index < tokens.count - 1 {
                index += 1

                if tokens[index].type == "source.lang.swift.syntaxtype.typeidentifier",
                    let subtype = extract(tokens[index], contents: contents) {
                    subtypes.append(subtype)
                } else { break }
            }

            typealiases.append(Typealias(aliasName: alias, typeName: subtypes.joined(separator: ".")))
        }
        return typealiases
    }

    fileprivate func isGeneric(source: [String: SourceKitRepresentable]) -> Bool {
        guard let substring = extract(.nameSuffix, from: source), substring.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") == true else { return false }
        return true
    }

    fileprivate func extract(_ substringIdentifier: SubstringIdentifier, from source: [String: SourceKitRepresentable]) -> String? {
        return extract(substringIdentifier, from: source, contents: self.contents)
    }

    fileprivate func extract(_ substringIdentifier: SubstringIdentifier, from source: [String: SourceKitRepresentable], contents: String) -> String? {
        let substring = substringIdentifier.range(for: source).flatMap { contents.substringWithByteRange(start: Int($0.offset), length: Int($0.length)) }
        return substring?.isEmpty == true ? nil : substring
    }

    fileprivate func extract(_ token: SyntaxToken) -> String? {
        return extract(token, contents: self.contents)
    }

    fileprivate func extract(_ token: SyntaxToken, contents: String) -> String? {
        return contents.bridge().substringWithByteRange(start: token.offset, length: token.length)
    }
}
