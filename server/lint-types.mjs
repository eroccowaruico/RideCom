// The pinned Worker TypeScript compiler supplies both syntax and inferred types.
import { resolve, relative } from 'node:path'
import { fileURLToPath } from 'node:url'
import { API, TypeFlags } from 'typescript/unstable/sync'
import { SyntaxKind as K } from 'typescript/unstable/ast'

const root = fileURLToPath(new URL('.', import.meta.url))
const selected = new Set(process.argv.slice(2).map(name => resolve(name)))
const counts = { error: 0, review: 0 }

function forwardedCall(node) {
    if (![K.FunctionDeclaration, K.MethodDeclaration, K.ArrowFunction, K.FunctionExpression].includes(node.kind)) return false
    let expr = node.body
    if (expr?.kind === K.Block) {
        if (expr.statements.length !== 1) return false
        const statement = expr.statements[0]
        if (![K.ReturnStatement, K.ExpressionStatement].includes(statement.kind)) return false
        expr = statement.expression
    }
    if (expr?.kind === K.AwaitExpression) expr = expr.expression
    return expr?.kind === K.CallExpression && node.parameters.length === expr.arguments.length
        && node.parameters.every((param, i) => !param.initializer && param.name.kind === K.Identifier
            && expr.arguments[i].kind === K.Identifier && expr.arguments[i].text === param.name.text)
}

function inspect(file, checker, shapes) {
    function report(pos, severity, rule) {
        if (selected.size && !selected.has(file.fileName)) return
        const { line, character } = file.getLineAndCharacterOfPosition(pos)
        console.log(`${relative(root, file.fileName)}:${line + 1}:${character + 1} ${severity} ${rule}`)
        counts[severity]++
    }
    const seenDirectives = new Set()
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
            let inner = node.expression
            while (inner.kind === K.ParenthesizedExpression) inner = inner.expression
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
                if (first) report(pos, 'review', 'duplicate-shape (see ' + first + ')')
                else shapes.set(shape, relative(root, file.fileName) + ':' + (file.getLineAndCharacterOfPosition(pos).line + 1))
            }
        }
        if (forwardedCall(node)) report(pos, 'review', 'forwarding-wrapper')
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
