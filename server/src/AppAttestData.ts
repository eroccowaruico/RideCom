export interface AppAttestLaunch {
    validationCategory: number
    bundleVersion: string | null
}

export async function sha256(bytes: Uint8Array) {
    return new Uint8Array(await crypto.subtle.digest('SHA-256', Uint8Array.from(bytes)))
}

export async function appAttestNonce(authenticatorData: Uint8Array, clientData: string) {
    const clientHash = await sha256(new TextEncoder().encode(clientData))
    const composite = new Uint8Array(authenticatorData.length + clientHash.length)
    composite.set(authenticatorData)
    composite.set(clientHash, authenticatorData.length)
    return sha256(composite)
}

export function appAttestLaunchMatches(fields: unknown, expected: AppAttestLaunch) {
    if (!(fields instanceof Map)) return false
    const category: unknown = fields.get('apple_validation_category_01')
    if (!(category instanceof Uint8Array) || category.length !== 4
        || new DataView(category.buffer, category.byteOffset, 4).getUint32(0, true) !== expected.validationCategory) return false
    const version: unknown = fields.get('apple_bundle_version_01')
    return version === undefined
        ? fields.size === 1 && expected.validationCategory === 3 && expected.bundleVersion === null
        : fields.size === 2 && typeof version === 'string' && version.length > 0 && version === expected.bundleVersion
}
