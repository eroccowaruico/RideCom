// The pinned Worker TypeScript compiler supplies both syntax and inferred types.
import { realpathSync } from 'node:fs'
import { dirname, resolve, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { API, SymbolFlags, TypeFlags } from 'typescript/unstable/sync'
import { SyntaxKind as K } from 'typescript/unstable/ast'

const root = fileURLToPath(new URL('.', import.meta.url))
const workerTypes = dirname(fileURLToPath(import.meta.resolve('@cloudflare/workers-types/package.json')))
const selected = new Set(process.argv.slice(2).map(name => resolve(name)))
const counts = { error: 0, review: 0 }

function withoutParentheses(node) {
    while (node.kind === K.ParenthesizedExpression) node = node.expression
    return node
}

function forwardedCall(node) {
    if (![K.FunctionDeclaration, K.MethodDeclaration, K.ArrowFunction, K.FunctionExpression].includes(node.kind)) return
    let expr = node.body
    if (expr?.kind === K.Block) {
        if (expr.statements.length !== 1) return
        const statement = expr.statements[0]
        if (![K.ReturnStatement, K.ExpressionStatement].includes(statement.kind)) return
        expr = statement.expression
    }
    if (expr?.kind === K.AwaitExpression) expr = expr.expression
    if (expr?.kind === K.CallExpression && node.parameters.length === expr.arguments.length
        && node.parameters.every((param, i) => !param.initializer && param.name.kind === K.Identifier
            && expr.arguments[i].kind === K.Identifier && expr.arguments[i].text === param.name.text)) return expr
}

function resolvedSymbol(node, checker) {
    const symbol = checker.getSymbolAtLocation(node)
    return symbol?.flags & SymbolFlags.Alias ? checker.getAliasedSymbol(symbol) : symbol
}

function referenceKey(node, checker) {
    const reference = withoutParentheses(node)
    switch (reference.kind) {
        case K.ThisKeyword: return 'this'
        case K.SuperKeyword: return 'super'
        case K.Identifier: return resolvedSymbol(reference, checker)?.id.toString()
        case K.PropertyAccessExpression:
        case K.ElementAccessExpression: {
            const name = reference.name ?? reference.argumentExpression
            if (reference.kind === K.ElementAccessExpression && ![K.StringLiteral, K.NumericLiteral].includes(name?.kind)) return
            const symbol = resolvedSymbol(name, checker)
            const receiver = referenceKey(reference.expression, checker)
            if (symbol && receiver) return `${receiver}.${symbol.id}`
        }
    }
}

function durableObjectContract(owner, checker) {
    if (owner.kind !== K.ClassDeclaration || !owner.modifiers?.some(modifier => modifier.kind === K.ExportKeyword)) return
    for (const clause of owner.heritageClauses ?? []) {
        for (const heritage of clause.types) {
            const contract = resolvedSymbol(heritage.expression, checker)
            if (contract?.name !== 'DurableObject') continue
            const declarationKind = clause.token === K.ExtendsKeyword ? K.ClassDeclaration : K.InterfaceDeclaration
            if (contract.declarations.some(declaration => declaration.kind === declarationKind
                && dirname(realpathSync(declaration.path)) === workerTypes)) {
                return { members: contract.getMembers(), rpc: clause.token === K.ExtendsKeyword, delegations: new Set() }
            }
        }
    }
}

function durableObjectEntryPoint(node, call, checker, contracts) {
    if (node.kind !== K.MethodDeclaration || node.name.kind !== K.Identifier
        || node.modifiers?.some(modifier => [K.StaticKeyword, K.PrivateKeyword, K.ProtectedKeyword].includes(modifier.kind))) return false
    const owner = node.parent
    if (!contracts.has(owner.id)) contracts.set(owner.id, durableObjectContract(owner, checker))
    const contract = contracts.get(owner.id)
    if (!contract) return false
    if (contract.members.has(node.name.text)) return true
    if (!contract.rpc) return false
    // Delegation exposes a collaborator's operation on the RPC prototype. A second
    // method that forwards to the same object's method still merits review.
    const callee = withoutParentheses(call.expression)
    if ([K.PropertyAccessExpression, K.ElementAccessExpression].includes(callee.kind)) {
        const receiver = withoutParentheses(callee.expression)
        if ([K.ThisKeyword, K.SuperKeyword].includes(receiver.kind)) return false
    }
    const target = referenceKey(callee, checker)
    if (!target) return false
    // All arguments already match their parameters in order. Compare their types
    // so an independent RPC with a different input contract can use the same target.
    const argumentTypes = checker.getTypeAtLocation(call.arguments)
    if (argumentTypes.some(type => !type || type.isErrorType())) return false
    const delegation = JSON.stringify([target, ...argumentTypes.map(type => type.id)])
    if (contract.delegations.has(delegation)) return false
    contract.delegations.add(delegation)
    return true
}

function inspect(file, checker, shapes) {
    function report(pos, severity, rule) {
        if (selected.size && !selected.has(file.fileName)) return
        const { line, character } = file.getLineAndCharacterOfPosition(pos)
        console.log(`${relative(root, file.fileName)}:${line + 1}:${character + 1} ${severity} ${rule}`)
        counts[severity]++
    }
    const seenDirectives = new Set()
    const contracts = new Map()
    function visit(node) {
        const pos = node.getStart(file)
        const trivia = file.text.slice(node.pos, pos)
        for (const match of trivia.matchAll(/(?:\/\/\/?|\/\*+|^\s*\*)[ \t]*@ts-(nocheck|expect-error)\b/gm)) {
            const offset = node.pos + match.index
            if (!seenDirectives.has(offset)) {
                seenDirectives.add(offset)
                report(offset, match[1] === 'nocheck' ? 'error' : 'review', `ts-${match[1]}`)
            }
        }
        if (node.kind === K.VariableDeclaration && !node.type && node.initializer
            && (checker.getTypeAtLocation(node.name)?.flags & TypeFlags.Any))
            report(pos, 'review', 'inferred-any')
        if (node.kind === K.AsExpression || node.kind === K.TypeAssertionExpression) {
            const inner = withoutParentheses(node.expression)
            if ([K.AsExpression, K.TypeAssertionExpression].includes(inner.kind)) report(pos, 'error', 'chained-assertion')
            else if (node.type.getText(file) !== 'const') report(pos, 'review', 'type-assertion')
        }
        if (node.kind === K.TypeAliasDeclaration && node.type.kind === K.TypeReference && !node.type.typeArguments?.length)
            report(pos, 'review', 'type-alias')
        if (node.kind === K.InterfaceDeclaration || node.kind === K.TypeAliasDeclaration) {
            const members = node.members ?? node.type?.members
            if (!node.heritageClauses?.length && members?.length
                && members.every(member => member.kind === K.PropertySignature && member.type)) {
                const shape = JSON.stringify(members.map(member => [
                    member.name.getText(file), !!member.questionToken, member.modifiers?.map(m => m.kind) ?? [],
                    checker.getTypeFromTypeNode(member.type)?.id,
                ]).sort((a, b) => a[0].localeCompare(b[0])))
                const first = shapes.get(shape)
                if (first) report(pos, 'review', `duplicate-shape (see ${first})`)
                else shapes.set(shape, `${relative(root, file.fileName)}:${file.getLineAndCharacterOfPosition(pos).line + 1}`)
            }
        }
        const call = forwardedCall(node)
        if (call && !durableObjectEntryPoint(node, call, checker, contracts)) report(pos, 'review', 'forwarding-wrapper')
        node.forEachChild(visit)
    }
    visit(file)
}

const api = new API({ cwd: root })
try {
    const config = resolve(root, 'tsconfig.json')
    const project = api.updateSnapshot({ openProjects: [config] }).getProject(config)
    if (!project?.rootFiles.length) throw new Error('No TypeScript inputs')
    const shapes = new Map()
    if ([...selected].some(name => !project.rootFiles.includes(name))) throw new Error('Input outside Worker tsconfig')
    for (const name of [...project.rootFiles].sort()) inspect(project.program.getSourceFile(name), project.checker, shapes)
    console.log(`Worker structure: errors=${counts.error} review=${counts.review}`)
    if (counts.error) process.exitCode = 1
} finally {
    api.close()
}
