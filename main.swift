import AVFoundation
import Cocoa

// Touch Bar: 30 punti di altezza. Tutto in punti, velocità in punti/secondo.
let groundY: CGFloat = 3
let gravity: CGFloat = -480
let jumpV: CGFloat = 120
let maxY = jumpV * jumpV / (2 * -gravity) // = 15: soffitto, oltre il dino uscirebbe dalla Touch Bar (3 + 15 + 12 = 30)

// Tipi di cactus (larghezza, altezza): basso, medio, alto e stretto, gruppo largo e basso
let cactusKinds: [(w: ClosedRange<CGFloat>, h: ClosedRange<CGFloat>)] = [
    (5...6, 5...7), (6...7, 8...10), (6...7, 11...13), (12...16, 6...8),
]

enum Power: CaseIterable {
    // scudo: assorbe un cactus · ali: doppio salto · clessidra: rallenta il mondo · fiore di fuoco: spara palle di fuoco
    // uovo: vita extra tenuta finché serve · bistecca: gigante, schiaccia i cactus · ruggito: spazza via i cactus a schermo
    // ambra: punti doppi
    case shield, wings, slow, fire, egg, steak, roar, amber
    var emoji: String { ["🛡️", "🪽", "⏳", "🌺", "🥚", "🍖", "🦖", "💎"][Power.allCases.firstIndex(of: self)!] }
    var duration: CGFloat {
        switch self {
        case .shield: 12
        case .wings, .fire, .amber: 10
        case .slow: 6
        case .steak: 8
        case .egg: .infinity // resta finché non salva il dino
        case .roar: 0.5 // istantaneo: la durata è solo l'onda d'urto disegnata
        }
    }
}

/// Palla di fuoco: avanza a velocità fissa sullo schermo e rimbalza sul terreno.
struct Fireball { var x: CGFloat, y: CGFloat, vy: CGFloat }
let fireballRadius: CGFloat = 1.6

struct Game {
    var playerY: CGFloat = 0 // altezza dal suolo
    var vy: CGFloat = 0
    var airJumped = false
    var obstacles: [CGRect] = []
    var items: [(rect: CGRect, power: Power)] = []
    var active: [Power: CGFloat] = [:] // secondi rimasti per ogni power-up attivo
    var speed: CGFloat = 180
    var distance: CGFloat = 0
    var nextSpawn: CGFloat = 300
    var over = false
    var paused = false
    var fireballs: [Fireball] = []
    var fireCooldown: CGFloat = 0
    var bursts: [(at: CGPoint, age: CGFloat)] = [] // cactus appena spaccati, per l'esplosione
    var points: CGFloat = 0 // separati dalla distanza: con l'ambra crescono il doppio
    var notice: (text: String, left: CGFloat)? // messaggio breve sulla barra ("ROAAAR!", "salvato dall'uovo")
    var coins: [CGPoint] = [] // centri delle monete sul percorso
    var coinsTaken = 0 // in questa partita (le monete totali le tiene il Wallet)
    var picked: [Power] = [] // power-up appena presi: l'app ne suona l'effetto e svuota la lista
    var sparkles: [(at: CGPoint, age: CGFloat)] = [] // scintille delle monete prese

    /// Arco di 5 monete centrato sopra un cactus: si prendono saltandolo.
    static func coinArc(over x: CGFloat) -> [CGPoint] {
        (0..<5).map { i in CGPoint(x: x - 24 + CGFloat(i) * 12, y: groundY + 6 + 11 * sin(.pi * CGFloat(i) / 4)) }
    }

    var score: Int { Int(points) }
    /// 1 normale, fino a 1,5 con la bistecca: cresce e si sgonfia in 0,3 s.
    var giant: CGFloat { active[.steak].map { 1 + 0.5 * min(1, (Power.steak.duration - $0) / 0.3, $0 / 0.3) } ?? 1 }
    var playerRect: CGRect { CGRect(x: 40, y: groundY + playerY, width: 14 * giant, height: 12 * giant) }

    mutating func jump() {
        if playerY == 0 { vy = jumpV }
        else if active[.wings] != nil && !airJumped { vy = jumpV * 0.85; airJumped = true }
    }

    /// Spara dalla bocca del dino; al massimo 3 palle in volo e una ogni 0,25 s.
    mutating func shoot() {
        guard active[.fire] != nil, !over, !paused, fireCooldown <= 0, fireballs.count < 3 else { return }
        fireballs.append(Fireball(x: playerRect.maxX, y: playerRect.minY + 7 * giant, vy: -30))
        fireCooldown = 0.25
    }

    mutating func step(_ dt: CGFloat, width: CGFloat) {
        guard !over && !paused else { return }
        for (p, t) in active { active[p] = t > dt ? t - dt : nil }
        if let n = notice { notice = n.left > dt ? (n.text, n.left - dt) : nil }

        vy += gravity * dt
        let ceiling = 30 - groundY - playerRect.height // da gigante il soffitto è più basso
        playerY = min(ceiling, max(0, playerY + vy * dt))
        if playerY == ceiling { vy = min(vy, 0) }
        if playerY == 0 { vy = 0; airJumped = false }

        let dx = speed * dt * (active[.slow] != nil ? 0.55 : 1)
        distance += dx
        points += dx / 10 * (active[.amber] != nil ? 2 : 1)
        speed += 4 * dt
        obstacles = obstacles.map { $0.offsetBy(dx: -dx, dy: 0) }.filter { $0.maxX > 0 }
        items = items.map { (rect: $0.rect.offsetBy(dx: -dx, dy: 0), power: $0.power) }.filter { $0.rect.maxX > 0 }

        nextSpawn -= dx
        if nextSpawn <= 0 {
            let k = cactusKinds.randomElement()!
            obstacles.append(CGRect(x: width, y: groundY, width: .random(in: k.w), height: .random(in: k.h)))
            // gap minimo > distanza percorsa in un salto, così ogni cactus è superabile
            nextSpawn = .random(in: speed * 0.75...speed * 1.8)
            let cactus = obstacles.last!
            if Int.random(in: 0..<3) == 0 { // monete: arco sopra il cactus, oppure fila a terra nel tratto libero dopo
                coins += Game.coinArc(over: cactus.midX)
            } else if nextSpawn > 140 && Bool.random() {
                coins += (0..<4).map { CGPoint(x: cactus.maxX + 40 + CGFloat($0) * 10, y: groundY + 5) }
            }
            // a volte un power-up, a metà strada verso il prossimo cactus così non si sovrappongono
            if items.isEmpty && Int.random(in: 0..<4) == 0 {
                items.append((CGRect(x: width + nextSpawn / 2, y: groundY + [2, 12].randomElement()!, width: 8, height: 8),
                              Power.allCases.randomElement()!))
            }
        }

        if let i = items.firstIndex(where: { $0.rect.intersects(playerRect) }) {
            let power = items.remove(at: i).power
            active[power] = power.duration
            picked.append(power)
            if power == .roar { // tutti i cactus a schermo esplodono subito
                bursts += obstacles.map { (CGPoint(x: $0.midX, y: $0.midY), 0) }
                obstacles.removeAll()
                notice = ("🦖 ROAAAR!", 1.2)
            }
        }

        // palle di fuoco: gravità, rimbalzo fisso sul terreno (~7 pt), spariscono oltre il bordo destro
        fireCooldown -= dt
        fireballs = fireballs.compactMap { f in
            var f = f
            f.vy += gravity * dt
            f.x += 260 * dt
            f.y += f.vy * dt
            if f.y < groundY + fireballRadius { f.y = groundY + fireballRadius; f.vy = 85 }
            return f.x < width + fireballRadius ? f : nil
        }
        for i in fireballs.indices.reversed() { // un cactus colpito si spacca, e la palla si consuma
            let f = fireballs[i], r = fireballRadius
            if let c = obstacles.firstIndex(where: { $0.intersects(CGRect(x: f.x - r, y: f.y - r, width: 2 * r, height: 2 * r)) }) {
                bursts.append((CGPoint(x: obstacles[c].midX, y: obstacles[c].midY), 0))
                obstacles.remove(at: c)
                fireballs.remove(at: i)
            }
        }
        bursts = bursts.compactMap { $0.age + dt < 0.4 ? (CGPoint(x: $0.at.x - dx, y: $0.at.y), $0.age + dt) : nil }

        // monete: scorrono col mondo; si prendono anche sfiorandole
        coins = coins.map { CGPoint(x: $0.x - dx, y: $0.y) }.filter { $0.x > -3 }
        let reach = playerRect.insetBy(dx: -3, dy: -3)
        sparkles += coins.filter { reach.contains($0) }.map { ($0, 0) }
        let left = coins.count
        coins.removeAll { reach.contains($0) }
        coinsTaken += left - coins.count
        sparkles = sparkles.compactMap { $0.age + dt < 0.45 ? (CGPoint(x: $0.at.x - dx, y: $0.at.y + dt * 12), $0.age + dt) : nil }

        // hitbox più piccole delle sagome: il dino non è un rettangolo
        let dino = playerRect.insetBy(dx: 2, dy: 1)
        if let i = obstacles.firstIndex(where: { $0.insetBy(dx: 1, dy: 1).intersects(dino) }) {
            // la bistecca schiaccia senza consumarsi; poi lo scudo; l'uovo è l'ultima salvezza
            if active[.steak] == nil && active[.shield] == nil && active[.egg] == nil { over = true; return }
            if active[.steak] == nil {
                if active[.shield] != nil { active[.shield] = nil } else { active[.egg] = nil; notice = ("🐣 Salvato dall'uovo!", 1.5) }
            }
            bursts.append((CGPoint(x: obstacles[i].midX, y: obstacles[i].midY), 0))
            obstacles.remove(at: i)
        }
    }
}

// MARK: - Ambientazioni (cambiano ogni 300 punti, con dissolvenza)

enum Back { case hills, volcanoes, mesas, sea, peaks, bigTrees, spires } // sfondo lontano
enum Props { case jungle, ferns, desert, beach, pines, reeds, bones }     // elementi vicini
enum Weather { case clear, snow, fog, fireflies }

struct Scene {
    var name: String
    var skyTop, skyBottom, far, mid, ground: NSColor
    var night: CGFloat // 0 = sole, 1 = luna e stelle
    var back: Back, props: Props, weather: Weather = .clear

    /// Solo i colori sfumano; gli elementi delle due ambientazioni vengono dissolti uno sull'altro.
    func blended(with o: Scene, _ f: CGFloat) -> Scene {
        func b(_ a: NSColor, _ c: NSColor) -> NSColor { a.blended(withFraction: f, of: c)! }
        var r = self
        r.skyTop = b(skyTop, o.skyTop); r.skyBottom = b(skyBottom, o.skyBottom)
        r.far = b(far, o.far); r.mid = b(mid, o.mid); r.ground = b(ground, o.ground)
        r.night = night + (o.night - night) * f
        return r
    }
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

let sceneLength: CGFloat = 3000 // distanza percorsa per ambientazione (= 300 punti)
let scenes = [
    Scene(name: "Giungla all'alba", skyTop: rgb(0.16, 0.15, 0.38), skyBottom: rgb(0.95, 0.55, 0.35),
          far: rgb(0.32, 0.18, 0.28), mid: rgb(0.08, 0.22, 0.12), ground: rgb(0.45, 0.3, 0.15), night: 0.15,
          back: .hills, props: .jungle),
    Scene(name: "Valle dei vulcani", skyTop: rgb(0.22, 0.48, 0.85), skyBottom: rgb(0.62, 0.82, 0.95),
          far: rgb(0.42, 0.26, 0.2), mid: rgb(0.1, 0.32, 0.14), ground: rgb(0.55, 0.38, 0.2), night: 0,
          back: .volcanoes, props: .ferns),
    Scene(name: "Canyon rosso", skyTop: rgb(0.3, 0.55, 0.85), skyBottom: rgb(0.98, 0.85, 0.6),
          far: rgb(0.75, 0.38, 0.22), mid: rgb(0.45, 0.3, 0.18), ground: rgb(0.85, 0.6, 0.35), night: 0,
          back: .mesas, props: .desert),
    Scene(name: "Costa preistorica", skyTop: rgb(0.4, 0.2, 0.5), skyBottom: rgb(1, 0.6, 0.45),
          far: rgb(0.25, 0.15, 0.25), mid: rgb(0.12, 0.1, 0.12), ground: rgb(0.9, 0.78, 0.55), night: 0.2,
          back: .sea, props: .beach),
    Scene(name: "Vette innevate", skyTop: rgb(0.35, 0.55, 0.85), skyBottom: rgb(0.85, 0.92, 1),
          far: rgb(0.45, 0.5, 0.62), mid: rgb(0.12, 0.3, 0.25), ground: rgb(0.9, 0.93, 0.97), night: 0,
          back: .peaks, props: .pines, weather: .snow),
    Scene(name: "Palude nebbiosa", skyTop: rgb(0.3, 0.38, 0.35), skyBottom: rgb(0.62, 0.7, 0.62),
          far: rgb(0.22, 0.3, 0.25), mid: rgb(0.1, 0.18, 0.12), ground: rgb(0.3, 0.25, 0.15), night: 0.1,
          back: .bigTrees, props: .reeds, weather: .fog),
    Scene(name: "Cimitero dei giganti", skyTop: rgb(0.2, 0.1, 0.25), skyBottom: rgb(0.75, 0.4, 0.45),
          far: rgb(0.3, 0.18, 0.25), mid: rgb(0.2, 0.12, 0.15), ground: rgb(0.42, 0.3, 0.25), night: 0.4,
          back: .spires, props: .bones),
    Scene(name: "Notte delle lucciole", skyTop: rgb(0.01, 0.01, 0.06), skyBottom: rgb(0.07, 0.1, 0.25),
          far: rgb(0.13, 0.1, 0.2), mid: rgb(0.04, 0.1, 0.07), ground: rgb(0.25, 0.18, 0.12), night: 1,
          back: .hills, props: .ferns, weather: .fireflies),
]

/// Numero pseudo-casuale stabile in 0..<1: lo stesso elemento di sfondo resta uguale mentre scorre.
/// Finalizzatore di MurmurHash3: indici vicini danno valori indipendenti (prima, coppie come hash01(k) e
/// hash01(k + 20) erano legate in modo lineare e le particelle finivano allineate in diagonale).
func hash01(_ i: Int) -> CGFloat {
    var x = UInt32(truncatingIfNeeded: i &+ 7)
    x ^= x >> 16; x = x &* 0x85eb_ca6b; x ^= x >> 13; x = x &* 0xc2b2_ae35; x ^= x >> 16
    return CGFloat(x >> 8) / CGFloat(1 << 24)
}

// MARK: - Disegno

func pill(_ r: NSRect) { NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2, yRadius: min(r.width, r.height) / 2).fill() }

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

func poly(_ pts: NSPoint...) { // riempie un poligono
    let path = NSBezierPath(); path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }; path.close(); path.fill()
}

func oval(_ r: NSRect) { NSBezierPath(ovalIn: r).fill() }

func drawCactus(_ r: CGRect) {
    if r.width > 10 { // gruppo: tre fusti, quello centrale più alto
        let sw = r.width / 3 - 0.5
        pill(NSRect(x: r.minX, y: r.minY, width: sw, height: r.height * 0.7))
        pill(NSRect(x: r.midX - sw / 2, y: r.minY, width: sw, height: r.height))
        pill(NSRect(x: r.maxX - sw, y: r.minY, width: sw, height: r.height * 0.8))
        return
    }
    let sw = r.width * 0.5, arm: CGFloat = 1.5
    pill(NSRect(x: r.midX - sw / 2, y: r.minY, width: sw, height: r.height))
    guard r.height >= 8 else { return } // i cactus bassi non hanno braccia
    let ly = r.minY + r.height * 0.4, ry = r.minY + r.height * 0.55
    NSRect(x: r.minX, y: ly, width: r.midX - r.minX, height: arm).fill()
    pill(NSRect(x: r.minX, y: ly, width: arm, height: r.height * 0.3))
    NSRect(x: r.midX, y: ry, width: r.maxX - r.midX, height: arm).fill()
    pill(NSRect(x: r.maxX - arm, y: ry, width: arm, height: r.height * 0.3))
}

func drawVolcano(_ x: CGFloat, height h: CGFloat, halfWidth hw: CGFloat, rock: NSColor, smoke: Bool = true) {
    let top = groundY + h, c: CGFloat = 3 // cima piatta: il cratere è largo 2c
    NSColor(white: 0.55, alpha: 0.35).setFill() // fumo
    for (dx, dy, r): (CGFloat, CGFloat, CGFloat) in smoke ? [(-1, 1.5, 1.5), (0.8, 3.5, 2), (-0.5, 6, 2.5)] : [] {
        NSBezierPath(ovalIn: NSRect(x: x + dx - r, y: top + dy - r, width: 2 * r, height: 2 * r)).fill()
    }
    rock.setFill()
    let cone = NSBezierPath()
    cone.move(to: NSPoint(x: x - hw, y: groundY)); cone.line(to: NSPoint(x: x - c, y: top))
    cone.line(to: NSPoint(x: x + c, y: top)); cone.line(to: NSPoint(x: x + hw, y: groundY)); cone.close(); cone.fill()
    // lava: bordo del cratere e due colate che scendono lungo i fianchi
    NSColor(srgbRed: 0.95, green: 0.35, blue: 0.1, alpha: 1).setFill()
    NSRect(x: x - c, y: top - 0.8, width: 2 * c, height: 0.8).fill()
    let run = hw - c
    poly(NSPoint(x: x - c, y: top), NSPoint(x: x - c + 1.4, y: top), NSPoint(x: x - c - run * 0.3, y: top - h * 0.3))
    poly(NSPoint(x: x + c, y: top), NSPoint(x: x + c - 1.4, y: top), NSPoint(x: x + c + run * 0.45, y: top - h * 0.45))
}

func drawPalm(_ x: CGFloat, height h: CGFloat) {
    for k in 0..<6 { // tronco leggermente piegato
        NSRect(x: x + CGFloat(k) * 0.35, y: groundY + CGFloat(k) * h / 6, width: 1.4, height: h / 6 + 0.3).fill()
    }
    let top = NSPoint(x: x + 2.4, y: groundY + h)
    for (dx, dy) in [(-6.0, -2.5), (6, -2), (-4, 2), (4.5, 2.2), (0.5, 3)] as [(CGFloat, CGFloat)] {
        poly(NSPoint(x: top.x, y: top.y + 0.8), NSPoint(x: top.x + dx, y: top.y + dy), NSPoint(x: top.x, y: top.y - 0.8))
    }
}

func drawFern(_ x: CGFloat, size s: CGFloat) {
    for a: CGFloat in [-1, -0.5, 0, 0.5, 1] {
        poly(NSPoint(x: x - 0.6, y: groundY), NSPoint(x: x + a * s * 0.6, y: groundY + s * (1 - abs(a) * 0.35)),
                 NSPoint(x: x + 0.6, y: groundY))
    }
}

func drawPtero(_ x: CGFloat, _ y: CGFloat, flap: CGFloat) {
    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 3.5, height: 1.3)).fill()
    poly(NSPoint(x: x + 3.2, y: y + 0.4), NSPoint(x: x + 5.5, y: y + 0.9), NSPoint(x: x + 3.2, y: y + 1.2)) // becco
    poly(NSPoint(x: x + 3.2, y: y + 1.1), NSPoint(x: x + 4.5, y: y + 2.2), NSPoint(x: x + 2.8, y: y + 1.2)) // cresta
    poly(NSPoint(x: x + 0.8, y: y + 0.7), NSPoint(x: x - 1, y: y + 0.7 + flap * 3), NSPoint(x: x + 2.6, y: y + 0.7)) // ala
}

func drawPine(_ x: CGFloat, height h: CGFloat) {
    NSRect(x: x - 0.5, y: groundY, width: 1, height: h * 0.3).fill()
    for k in 0..<3 {
        let y0 = groundY + h * (0.2 + CGFloat(k) * 0.22), hw = 3.6 - CGFloat(k) * 0.9
        poly(P(x - hw, y0), P(x, y0 + h * 0.4), P(x + hw, y0))
    }
    NSColor.white.setFill() // neve sulla punta
    poly(P(x - 1.1, groundY + h * 0.86), P(x, groundY + h * 1.04), P(x + 1.1, groundY + h * 0.86))
}

/// Sfondo lontano: un gruppo di elementi del tipo dell'ambientazione centrato intorno a x.
func drawBack(_ kind: Back, _ x: CGFloat, _ i: Int, _ s: Scene) {
    let r1 = hash01(i + 1), r2 = hash01(i + 2)
    s.far.setFill()
    switch kind {
    case .hills:
        for (dx, k) in [(0.0, 0), (70, 3)] as [(CGFloat, Int)] {
            let h = 8 + hash01(i + k) * 7, hw = 35 + hash01(i + k + 1) * 20
            oval(NSRect(x: x + dx - hw, y: groundY - h, width: 2 * hw, height: 2 * h))
        }
    case .volcanoes:
        drawVolcano(x, height: 17 + r1 * 7, halfWidth: 30 + r2 * 15, rock: s.far)
    case .mesas: // altopiani a cima piatta con strati di roccia
        let h = 10 + r1 * 7, hw = 20 + r2 * 18
        poly(P(x - hw, groundY), P(x - hw + 3, groundY + h), P(x + hw - 3, groundY + h), P(x + hw, groundY))
        s.far.blended(withFraction: 0.25, of: .black)!.setFill()
        for k in 1...2 { NSRect(x: x - hw + 1.5, y: groundY + h * CGFloat(k) / 3, width: 2 * hw - 3, height: 0.6).fill() }
    case .sea: // faraglioni nel mare
        for k in 0..<2 {
            let h = 8 + hash01(i + k) * 8, hw = 2.5 + hash01(i + k + 5) * 3, cx = x + CGFloat(k) * 14
            poly(P(cx - hw - 1.5, groundY), P(cx - hw, groundY + h), P(cx + hw, groundY + h), P(cx + hw + 1.5, groundY))
        }
    case .peaks: // montagne con la neve in cima
        let h = 16 + r1 * 8, hw = 30 + r2 * 15
        poly(P(x - hw, groundY), P(x, groundY + h), P(x + hw, groundY))
        NSColor.white.withAlphaComponent(0.9).setFill()
        poly(P(x - hw * 0.35, groundY + h * 0.65), P(x, groundY + h), P(x + hw * 0.35, groundY + h * 0.65))
    case .bigTrees: // alberi giganti con chioma alta e stretta
        for k in 0..<5 {
            let tx = x + CGFloat(k) * 12 + hash01(i + k) * 4, th = 16 + hash01(i + k + 9) * 9
            NSRect(x: tx - 0.7, y: groundY, width: 1.4, height: th * 0.4).fill()
            pill(NSRect(x: tx - 3, y: groundY + th * 0.35, width: 6, height: th * 0.65))
        }
    case .spires: // guglie di roccia
        for k in 0..<3 {
            let sx = x + CGFloat(k) * 9, h = 10 + hash01(i + k) * 12, hw = 1.8 + hash01(i + k + 5) * 1.2
            poly(P(sx - hw - 1, groundY), P(sx - hw, groundY + h), P(sx + hw, groundY + h), P(sx + hw + 1, groundY))
            oval(NSRect(x: sx - hw - 0.8, y: groundY + h - 0.8, width: 2 * hw + 1.6, height: 2.2))
        }
    }
}

/// Elementi vicini (piante, rocce, ossa); non tutti gli slot hanno qualcosa, così c'è varietà.
func drawProps(_ kind: Props, _ x: CGFloat, _ i: Int, _ s: Scene) {
    let r = hash01(i), r3 = hash01(i + 3)
    s.mid.setFill(); s.mid.setStroke()
    func boulder() { oval(NSRect(x: x, y: groundY - 2, width: 5 + r3 * 4, height: 5 + r3 * 2)) }
    switch kind {
    case .jungle:
        if r < 0.3 { drawPalm(x, height: 10 + r3 * 5) } else if r < 0.75 { drawFern(x, size: 4 + r3 * 3) }
    case .ferns:
        if r < 0.45 { drawFern(x, size: 4 + r3 * 3) } else if r < 0.75 { boulder() }
    case .desert:
        if r < 0.35 { boulder() } else if r < 0.7 { // cespuglio secco
            let bush = NSBezierPath(); bush.lineWidth = 0.5
            for a: CGFloat in [-1, -0.4, 0.3, 1] { bush.move(to: P(x, groundY)); bush.line(to: P(x + a * 2.8, groundY + 2.5 + r3 * 2 - abs(a))) }
            bush.stroke()
        }
    case .beach:
        if r < 0.4 { drawPalm(x, height: 9 + r3 * 6) } else if r < 0.6 { boulder() }
    case .pines:
        if r < 0.6 { drawPine(x, height: 8 + r3 * 7) }
    case .reeds: // canne palustri
        guard r < 0.8 else { return }
        for k in 0..<5 {
            let sx = x + CGFloat(k) * 1.7, h = 4 + hash01(i + k * 7) * 7
            NSRect(x: sx, y: groundY, width: 0.5, height: h).fill()
            if k % 2 == 0 { pill(NSRect(x: sx - 0.4, y: groundY + h - 2.5, width: 1.3, height: 2.5)) }
        }
    case .bones:
        let bone = NSColor(white: 0.88, alpha: 1).blended(withFraction: 0.35, of: s.mid)!
        bone.setFill(); bone.setStroke()
        if r < 0.35 { // gabbia toracica con teschio
            for k in 0..<4 {
                let rib = NSBezierPath(); rib.lineWidth = 0.6
                rib.appendArc(withCenter: P(x + CGFloat(k) * 2.4, groundY), radius: k == 1 || k == 2 ? 4 : 3, startAngle: 20, endAngle: 160)
                rib.stroke()
            }
            NSRect(x: x - 2, y: groundY + 3.2, width: 11, height: 0.7).fill()
            oval(NSRect(x: x + 9, y: groundY, width: 4, height: 3))
            s.mid.setFill(); oval(NSRect(x: x + 10.8, y: groundY + 1.3, width: 1, height: 1))
        } else if r < 0.55 { // osso
            pill(NSRect(x: x, y: groundY + 0.3, width: 5, height: 0.9))
            for (bx, by) in [(x - 0.6, groundY), (x - 0.6, groundY + 0.9), (x + 4.4, groundY), (x + 4.4, groundY + 0.9)] {
                oval(NSRect(x: bx, y: by, width: 1.2, height: 1.2))
            }
        }
    }
}

// MARK: - Personalizzazione del dinosauro

enum Species: Int, CaseIterable, Codable {
    case rex, triceratops, stego, brachio
    var title: String { ["T-Rex", "Triceratopo", "Stegosauro", "Brachiosauro"][rawValue] }
    /// Come gli accessori calzano su questa specie (coordinate nel rettangolo 14x12).
    var fit: Fit {
        switch self {
        case .rex: Fit(hat: P(11.4, 11.7), hatAngle: 10, hatScale: 1, eye: P(12.2, 10.3), eyeScale: 1,
                       neck: P(10.25, 7.2), neckAngle: 90, neckWidth: 2.6, back: P(7.2, 8.6))
        case .triceratops: Fit(hat: P(10.7, 7.3), hatAngle: 14, hatScale: 0.85, eye: P(11.9, 6.3), eyeScale: 0.95,
                               neck: P(9.8, 5.2), neckAngle: 15, neckWidth: 2.3, back: P(5.6, 8.6))
        case .stego: Fit(hat: P(12.2, 6.1), hatAngle: 8, hatScale: 0.7, eye: P(12.7, 5.2), eyeScale: 0.75,
                         neck: P(10.2, 5.1), neckAngle: -15, neckWidth: 2.3, back: P(6.4, 8.8))
        case .brachio: Fit(hat: P(12.1, 11.7), hatAngle: 8, hatScale: 0.8, eye: P(12.8, 10.9), eyeScale: 0.85,
                           neck: P(10.8, 9.2), neckAngle: 53, neckWidth: 1.9, back: P(5.5, 8.3))
        }
    }
}

/// Dove e come si posano gli accessori: il cappello appena dentro la cima della testa, inclinato all'indietro e
/// scalato sulla testa; il collo ha una direzione (verso la testa) e uno spessore, così fasce e collane lo seguono.
struct Fit {
    var hat: NSPoint, hatAngle: CGFloat, hatScale: CGFloat
    var eye: NSPoint, eyeScale: CGFloat
    var neck: NSPoint, neckAngle: CGFloat, neckWidth: CGFloat
    var back: NSPoint // sopra la schiena: dove si attaccano mantello e jetpack
}
enum Hat: Int, CaseIterable, Codable {
    case none, safari, topHat, cap, crown, cowboy, party
    var title: String { ["Nessuno", "Casco da esploratore", "Cilindro", "Cappellino", "Corona", "Da cowboy", "Da festa"][rawValue] }
}
enum Glasses: Int, CaseIterable, Codable {
    case none, sun, round, monocle, heart
    var title: String { ["Nessuno", "Da sole", "Tondi", "Monocolo", "A cuore"][rawValue] }
}
enum Neck: Int, CaseIterable, Codable {
    case none, bandana, bowTie, necklace
    var title: String { ["Niente", "Bandana", "Papillon", "Collana d'oro"][rawValue] }
}

struct Look: Codable, Equatable {
    var species = Species.rex, hat = Hat.none, glasses = Glasses.none, neck = Neck.none
    var skin: [CGFloat] = [0.2, 0.7, 0.75], accent: [CGFloat] = [1, 0.58, 0] // rgb
    // dal negozio; opzionali così i salvataggi di prima (senza questi campi) si leggono ancora
    var costume: Costume? = nil, gadget: Gadget? = nil
    var skinColor: NSColor { rgb(skin[0], skin[1], skin[2]) }
    var accentColor: NSColor { rgb(accent[0], accent[1], accent[2]) }

    static func load() -> Look {
        UserDefaults.standard.data(forKey: "look").flatMap { try? JSONDecoder().decode(Look.self, from: $0) } ?? Look()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "look") }
}

// MARK: - Negozio: skin e accessori speciali comprati con le monete

enum Costume: String, CaseIterable, Codable { case rainbow, inferno, robot, ghost, galaxy }
enum Gadget: String, CaseIterable, Codable { case headphones, cape, jetpack, storm, laser }

enum ShopItem: Hashable {
    case costume(Costume), gadget(Gadget)
    static let all = Costume.allCases.map { ShopItem.costume($0) } + Gadget.allCases.map { ShopItem.gadget($0) }

    var id: String {
        switch self { case .costume(let c): "skin." + c.rawValue
                      case .gadget(let g): "extra." + g.rawValue }
    }
    var title: String {
        switch self {
        case .costume(let c): ["🌈 Arcobaleno", "🔥 Inferno", "🤖 Robo-Rex", "👻 Fantasma", "🌌 Galassia"][Costume.allCases.firstIndex(of: c)!]
        case .gadget(let g): ["🎧 Cuffie da DJ", "🦸 Mantello", "🚀 Jetpack", "⛈️ Nuvola temporale", "🔴 Occhi laser"][Gadget.allCases.firstIndex(of: g)!]
        }
    }
    var price: Int {
        switch self {
        case .costume(let c): [150, 200, 250, 300, 400][Costume.allCases.firstIndex(of: c)!]
        case .gadget(let g): [60, 80, 120, 150, 200][Gadget.allCases.firstIndex(of: g)!]
        }
    }
    func isWorn(in look: Look) -> Bool {
        switch self { case .costume(let c): look.costume == c
                      case .gadget(let g): look.gadget == g }
    }
    /// `look` con questo oggetto indossato (`on`) o tolto.
    func wearing(_ on: Bool, in look: Look) -> Look {
        var l = look
        switch self { case .costume(let c): l.costume = on ? c : nil
                      case .gadget(let g): l.gadget = on ? g : nil }
        return l
    }
}

/// Monete, record assoluto e acquisti: salvati nelle preferenze, restano tra una sessione e l'altra.
struct Wallet: Codable, Equatable {
    var coins = 0, best = 0
    var owned: Set<String> = []

    /// false se le monete non bastano o l'oggetto è già tuo: non si paga mai due volte.
    mutating func buy(_ item: ShopItem) -> Bool {
        guard !owned.contains(item.id), coins >= item.price else { return false }
        coins -= item.price
        owned.insert(item.id)
        return true
    }

    static func load() -> Wallet {
        UserDefaults.standard.data(forKey: "wallet").flatMap { try? JSONDecoder().decode(Wallet.self, from: $0) } ?? Wallet()
    }
    func save() { UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: "wallet") }
}

func frac(_ x: CGFloat) -> CGFloat { x - floor(x) }

/// Disegna in un sistema di riferimento locale: origine in `at`, ruotato di `angle` gradi, scalato di `scale`.
func local(_ at: NSPoint, angle: CGFloat = 0, scale: CGFloat = 1, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: at.x, yBy: at.y); t.rotate(byDegrees: angle); t.scale(by: scale); t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func strokeLine(_ pts: NSPoint..., width: CGFloat) {
    let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }
    p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
}

/// Cappello con la base in (0, 0), rivolto a destra come il dinosauro.
func drawHat(_ kind: Hat) {
    let shine = NSColor.white.withAlphaComponent(0.3)
    switch kind {
    case .none: break
    case .safari: // casco da esploratore: cupola, fascia, tesa larga, bottoncino
        let khaki = rgb(0.86, 0.78, 0.55)
        khaki.setFill()
        let dome = NSBezierPath(); dome.move(to: P(-2, 0.2)); dome.curve(to: P(2, 0.2), controlPoint1: P(-2, 3.4), controlPoint2: P(2, 3.4)); dome.close(); dome.fill()
        rgb(0.45, 0.33, 0.18).setFill(); NSRect(x: -1.95, y: 0.35, width: 3.9, height: 0.55).fill()
        khaki.blended(withFraction: 0.2, of: .black)!.setFill(); oval(NSRect(x: -2.9, y: -0.35, width: 5.8, height: 0.95))
        shine.setFill(); oval(NSRect(x: -1.1, y: 1.5, width: 1.2, height: 0.8))
        khaki.blended(withFraction: 0.3, of: .black)!.setFill(); oval(NSRect(x: -0.25, y: 2.45, width: 0.5, height: 0.35))
    case .topHat: // cilindro leggermente svasato, nastro rosso, tesa curva
        let black = rgb(0.1, 0.1, 0.13)
        black.setFill(); poly(P(-1.35, 0.1), P(-1.55, 3.3), P(1.55, 3.3), P(1.35, 0.1))
        rgb(0.22, 0.22, 0.27).setFill(); oval(NSRect(x: -1.55, y: 3.05, width: 3.1, height: 0.5))
        rgb(0.75, 0.1, 0.15).setFill(); poly(P(-1.37, 0.4), P(-1.42, 1), P(1.42, 1), P(1.37, 0.4))
        black.setFill()
        let brim = NSBezierPath(); brim.move(to: P(-2.4, 0.45))
        brim.curve(to: P(2.4, 0.45), controlPoint1: P(-1.2, -0.45), controlPoint2: P(1.2, -0.45))
        brim.curve(to: P(-2.4, 0.45), controlPoint1: P(1.2, 0.05), controlPoint2: P(-1.2, 0.05)); brim.fill()
        shine.setFill(); NSRect(x: 0.75, y: 1.2, width: 0.3, height: 1.8).fill()
    case .cap: // cappellino: cupola, cucitura, bordo bianco, visiera in avanti
        let red = rgb(0.85, 0.15, 0.2), dark = red.blended(withFraction: 0.25, of: .black)!
        red.setFill()
        let dome = NSBezierPath(); dome.move(to: P(-1.9, 0)); dome.curve(to: P(1.9, 0), controlPoint1: P(-1.9, 2.8), controlPoint2: P(1.9, 2.8)); dome.close(); dome.fill()
        dark.setFill(); poly(P(1.3, 0.35), P(3.7, 0), P(3.6, -0.4), P(1.2, -0.25))
        dark.setStroke()
        let seam = NSBezierPath(); seam.move(to: P(0, 2.1)); seam.curve(to: P(0.3, 0.1), controlPoint1: P(0.5, 1.5), controlPoint2: P(0.45, 0.6))
        seam.lineWidth = 0.15; seam.stroke()
        NSColor.white.setFill(); NSRect(x: -1.85, y: 0, width: 3.7, height: 0.35).fill(); oval(NSRect(x: -0.3, y: 1.95, width: 0.6, height: 0.45))
        shine.setFill(); oval(NSRect(x: -1.2, y: 1.1, width: 1, height: 0.6))
    case .crown: // tre punte con palline, rubino e zaffiri
        rgb(1, 0.8, 0.2).setFill()
        poly(P(-1.9, 0), P(-2, 2.2), P(-1, 1.1), P(0, 2.6), P(1, 1.1), P(2, 2.2), P(1.9, 0))
        for (x, y): (CGFloat, CGFloat) in [(-2, 2.2), (0, 2.6), (2, 2.2)] { oval(NSRect(x: x - 0.3, y: y - 0.15, width: 0.6, height: 0.6)) }
        rgb(0.75, 0.55, 0.1).setFill(); NSRect(x: -1.9, y: 0, width: 3.8, height: 0.25).fill()
        rgb(0.85, 0.1, 0.2).setFill(); oval(NSRect(x: -0.35, y: 0.45, width: 0.7, height: 0.7))
        rgb(0.2, 0.45, 0.95).setFill(); for x: CGFloat in [-1.3, 1.3] { oval(NSRect(x: x - 0.25, y: 0.5, width: 0.5, height: 0.5)) }
        shine.setFill(); poly(P(-1.5, 0.4), P(-1.6, 1.5), P(-1.25, 1.2), P(-1.15, 0.4))
    case .cowboy: // calotta con la piega, nastro, tesa rialzata ai lati
        let brown = rgb(0.58, 0.36, 0.17)
        brown.setFill(); poly(P(-1.5, 0.2), P(-1.65, 2.1), P(-0.6, 2.6), P(0, 2.15), P(0.6, 2.6), P(1.65, 2.1), P(1.5, 0.2))
        rgb(0.3, 0.17, 0.08).setFill(); NSRect(x: -1.53, y: 0.4, width: 3.06, height: 0.45).fill()
        brown.blended(withFraction: 0.15, of: .black)!.setFill()
        let brim = NSBezierPath(); brim.move(to: P(-3.4, 1))
        brim.curve(to: P(3.4, 1), controlPoint1: P(-2, -0.6), controlPoint2: P(2, -0.6))
        brim.curve(to: P(-3.4, 1), controlPoint1: P(2, 0), controlPoint2: P(-2, 0)); brim.fill()
        shine.setFill(); oval(NSRect(x: -1.2, y: 1.2, width: 0.9, height: 0.7))
    case .party: // cono a strisce con pon pon
        let cone = NSBezierPath(); cone.move(to: P(-1.4, 0)); cone.line(to: P(0.3, 3.8)); cone.line(to: P(1.4, 0)); cone.close()
        rgb(0.85, 0.2, 0.75).setFill(); cone.fill()
        NSGraphicsContext.saveGraphicsState(); cone.addClip() // strisce solo dentro il cono
        rgb(1, 0.88, 0.25).setFill()
        for y: CGFloat in [0.6, 1.8, 3] { poly(P(-2, y), P(2, y + 0.6), P(2, y + 1), P(-2, y + 0.4)) }
        NSGraphicsContext.restoreGraphicsState()
        rgb(0.3, 0.85, 0.95).setFill(); oval(NSRect(x: -0.35, y: 3.4, width: 1.3, height: 1.3))
        NSColor.white.setFill(); NSRect(x: -1.45, y: -0.1, width: 2.9, height: 0.3).fill()
    }
}

/// Occhiali centrati sull'occhio in (0, 0): lente, riflesso, ponte verso il muso e stanghetta verso l'orecchio.
func drawGlasses(_ kind: Glasses) {
    func arms(_ c: NSColor, _ half: CGFloat) {
        c.setStroke(); strokeLine(P(-half, 0.35), P(-3.3, 0.75), width: 0.3); strokeLine(P(half, 0.2), P(half + 0.55, 0.05), width: 0.3)
    }
    let gleam = NSColor.white.withAlphaComponent(0.55)
    switch kind {
    case .none: break
    case .sun: // a goccia, lente scura
        let lens = NSBezierPath(); lens.move(to: P(-1.35, 0.75)); lens.line(to: P(1.35, 0.75))
        lens.curve(to: P(0.2, -1.05), controlPoint1: P(1.45, -0.4), controlPoint2: P(0.9, -1.05))
        lens.curve(to: P(-1.35, 0.75), controlPoint1: P(-0.9, -1.05), controlPoint2: P(-1.5, -0.3)); lens.close()
        rgb(0.08, 0.08, 0.12).setFill(); lens.fill()
        rgb(0.25, 0.25, 0.3).setStroke(); lens.lineWidth = 0.22; lens.stroke()
        gleam.setStroke(); strokeLine(P(-0.6, 0.35), P(0.1, -0.4), width: 0.25)
        arms(rgb(0.25, 0.25, 0.3), 1.35)
    case .round: // montatura tonda, lente appena azzurrata: l'occhio si vede
        let frame = NSBezierPath(ovalIn: NSRect(x: -1.15, y: -1.15, width: 2.3, height: 2.3))
        NSColor(srgbRed: 0.7, green: 0.9, blue: 1, alpha: 0.25).setFill(); frame.fill()
        rgb(0.3, 0.18, 0.1).setStroke(); frame.lineWidth = 0.3; frame.stroke()
        gleam.setStroke(); strokeLine(P(-0.55, 0.45), P(-0.15, 0.75), width: 0.18)
        arms(rgb(0.3, 0.18, 0.1), 1.15)
    case .monocle: // anello d'oro e catenella che scende
        let ring = NSBezierPath(ovalIn: NSRect(x: -1.05, y: -1.05, width: 2.1, height: 2.1))
        NSColor(srgbRed: 1, green: 0.95, blue: 0.8, alpha: 0.2).setFill(); ring.fill()
        rgb(1, 0.8, 0.2).setStroke(); ring.lineWidth = 0.28; ring.stroke()
        let chain = NSBezierPath(); chain.move(to: P(-0.5, -0.95))
        chain.curve(to: P(-2.2, -3.4), controlPoint1: P(-0.4, -2.4), controlPoint2: P(-1.4, -3.3))
        chain.lineWidth = 0.15; chain.setLineDash([0.3, 0.2], count: 2, phase: 0); chain.stroke()
        gleam.setStroke(); strokeLine(P(0.2, 0.5), P(0.55, 0.2), width: 0.15)
    case .heart: // lente a cuore rosa trasparente
        let heart = NSBezierPath(); heart.move(to: P(0, -1.2))
        heart.curve(to: P(-1.3, 0.35), controlPoint1: P(-0.6, -0.7), controlPoint2: P(-1.35, -0.3))
        heart.curve(to: P(0, 0.55), controlPoint1: P(-1.25, 1.2), controlPoint2: P(-0.25, 1.15))
        heart.curve(to: P(1.3, 0.35), controlPoint1: P(0.25, 1.15), controlPoint2: P(1.25, 1.2))
        heart.curve(to: P(0, -1.2), controlPoint1: P(1.35, -0.3), controlPoint2: P(0.6, -0.7))
        NSColor(srgbRed: 1, green: 0.3, blue: 0.55, alpha: 0.8).setFill(); heart.fill()
        rgb(0.85, 0.1, 0.4).setStroke(); heart.lineWidth = 0.22; heart.stroke()
        gleam.setStroke(); strokeLine(P(-0.8, 0.45), P(-0.45, 0.75), width: 0.18)
        arms(rgb(0.85, 0.1, 0.4), 1.3)
    }
}

/// Accessori al collo: la fascia gira attorno al collo seguendone la direzione, ciò che pende scende dalla gola.
func drawNeckwear(_ kind: Neck, at n: NSPoint, angle: CGFloat, width w: CGFloat) {
    let a = angle * .pi / 180
    let front = NSPoint(x: n.x + sin(a) * w * 0.38, y: n.y - cos(a) * w * 0.38) // lato gola, appena dentro il bordo
    let k = min(1, w / 2.8) // colli sottili, accessori più piccoli
    switch kind {
    case .none: break
    case .bandana:
        let red = rgb(0.82, 0.12, 0.14)
        red.setFill(); local(n, angle: angle) { pill(NSRect(x: -0.6, y: -w / 2 - 0.15, width: 1.2, height: w + 0.3)) }
        local(front, scale: k) {
            red.setFill(); poly(P(-1.1, 0.4), P(1, 0.4), P(-0.1, -1.9)) // punta che pende
            NSColor.white.withAlphaComponent(0.85).setFill()
            for (x, y): (CGFloat, CGFloat) in [(-0.45, -0.3), (0.3, -0.1), (-0.1, -1)] { oval(NSRect(x: x - 0.15, y: y - 0.15, width: 0.3, height: 0.3)) }
            red.blended(withFraction: 0.35, of: .black)!.setFill(); oval(NSRect(x: -0.45, y: 0, width: 0.9, height: 0.7)) // nodo
        }
    case .bowTie:
        local(front, scale: k) { // sempre di fronte, si legge meglio
            let c = rgb(0.12, 0.12, 0.18)
            c.setFill()
            poly(P(0, 0), P(-1.6, 0.85), P(-1.35, 0), P(-1.6, -0.85)); poly(P(0, 0), P(1.6, 0.85), P(1.35, 0), P(1.6, -0.85))
            NSColor.white.withAlphaComponent(0.25).setFill(); poly(P(-0.4, 0.15), P(-1.3, 0.6), P(-1.2, 0.3))
            c.blended(withFraction: 0.35, of: .white)!.setFill(); pill(NSRect(x: -0.4, y: -0.45, width: 0.8, height: 0.9))
        }
    case .necklace:
        let gold = rgb(1, 0.8, 0.2)
        gold.setFill()
        local(n, angle: angle) { // perle lungo il collo, leggermente incurvate
            for i in 0...4 {
                let y = w / 2 - CGFloat(i) * w / 4
                oval(NSRect(x: -0.3 - 0.3 * (1 - pow(y / (w / 2), 2)), y: y - 0.3, width: 0.6, height: 0.6))
            }
        }
        local(front, scale: k) { // ciondolo con rubino
            gold.setFill(); NSRect(x: -0.08, y: -0.7, width: 0.16, height: 0.7).fill(); oval(NSRect(x: -0.6, y: -1.8, width: 1.2, height: 1.2))
            rgb(0.85, 0.1, 0.2).setFill(); oval(NSRect(x: -0.3, y: -1.5, width: 0.6, height: 0.6))
            NSColor.white.withAlphaComponent(0.6).setFill(); oval(NSRect(x: -0.4, y: -1, width: 0.3, height: 0.2))
        }
    }
}

/// Zampa a due segmenti (coscia e stinco) con piede. `phase` è la fase continua del passo:
/// il piede avanza sollevato e torna indietro appoggiato a terra; nil = in salto, zampa raccolta.
func drawLeg(hip: NSPoint, ground: CGFloat, length L: CGFloat, width w: CGFloat, phase: CGFloat?) {
    let foot = phase.map { NSPoint(x: hip.x + sin($0) * 1.5, y: ground + w / 2 + max(0, cos($0)) * 1.1) }
        ?? NSPoint(x: hip.x - 0.4, y: hip.y - L * 0.65)
    let vx = foot.x - hip.x, vy = foot.y - hip.y, d = max(0.01, hypot(vx, vy))
    let bend = sqrt(max(0, L * L / 4 - d * d / 4)) // cinematica inversa: due segmenti lunghi L/2
    let knee = NSPoint(x: hip.x + vx / 2 - vy / d * bend, y: hip.y + vy / 2 + vx / d * bend) // ginocchio in avanti
    let thigh = NSBezierPath(); thigh.move(to: hip); thigh.line(to: knee)
    thigh.lineWidth = w * 1.4; thigh.lineCapStyle = .round; thigh.stroke()
    let shin = NSBezierPath(); shin.move(to: knee); shin.line(to: foot); shin.line(to: NSPoint(x: foot.x + 1.1, y: foot.y))
    shin.lineWidth = w; shin.lineCapStyle = .round; shin.lineJoinStyle = .round; shin.stroke()
}

func fillPath(_ pts: [NSPoint]) {
    let path = NSBezierPath(); path.move(to: pts[0]); pts.dropFirst().forEach { path.line(to: $0) }; path.close(); path.fill()
}

/// Stella a quattro punte (scintille).
func sparkle(_ c: NSPoint, _ s: CGFloat) {
    poly(P(c.x, c.y + s), P(c.x + s * 0.25, c.y + s * 0.25), P(c.x + s, c.y), P(c.x + s * 0.25, c.y - s * 0.25),
         P(c.x, c.y - s), P(c.x - s * 0.25, c.y - s * 0.25), P(c.x - s, c.y), P(c.x - s * 0.25, c.y + s * 0.25))
}

/// Texture animata della skin, dipinta solo sopra il corpo (chi chiama usa la composizione sourceAtop).
func drawCostumeTexture(_ c: Costume, in box: NSRect, _ t: CGFloat) {
    switch c {
    case .rainbow: // arcobaleno che scorre in diagonale
        let colors = (0..<8).map { NSColor(hue: frac(CGFloat($0) / 7 + t * 0.6), saturation: 0.8, brightness: 1, alpha: 1) }
        NSGradient(colors: colors)!.draw(in: box, angle: -35)
    case .inferno: // roccia incandescente con crepe di lava che pulsano
        NSGradient(colors: [rgb(1, 0.55, 0.05), rgb(0.75, 0.1, 0.02), rgb(0.22, 0.02, 0.02)])!.draw(in: box, angle: 90)
        NSColor(srgbRed: 1, green: 0.92, blue: 0.3, alpha: 0.55 + 0.45 * sin(t * 7)).setStroke()
        for k in 0..<7 {
            let x = box.minX + 2 + hash01(k) * (box.width - 4), y = box.minY + 2 + hash01(k + 10) * (box.height - 4)
            strokeLine(P(x, y), P(x + 1.2, y - 1), P(x + 0.6, y - 2.2), P(x + 1.8, y - 3), width: 0.35)
        }
    case .robot: // cromo con un riflesso che passa, pannelli e rivetti
        NSGradient(colors: [rgb(0.55, 0.6, 0.68), rgb(0.93, 0.95, 0.98), rgb(0.5, 0.55, 0.63), rgb(0.82, 0.85, 0.9)])!.draw(in: box, angle: 90)
        let x = box.minX - 6 + frac(t * 0.8) * (box.width + 12)
        NSColor.white.withAlphaComponent(0.85).setFill(); poly(P(x, box.minY), P(x + 2, box.minY), P(x + 6, box.maxY), P(x + 4, box.maxY))
        rgb(0.32, 0.35, 0.42).setFill()
        for k in 0..<10 { oval(NSRect(x: box.minX + hash01(k + 3) * box.width, y: box.minY + hash01(k + 30) * box.height, width: 0.45, height: 0.45)) }
        for y in stride(from: box.minY + 4, to: box.maxY, by: 4) { NSRect(x: box.minX, y: y, width: box.width, height: 0.15).fill() }
    case .ghost:
        NSGradient(colors: [rgb(0.88, 0.97, 1), rgb(0.6, 0.8, 1)])!.draw(in: box, angle: 90)
    case .galaxy: // nebulosa che ruota lentamente, stelle che brillano e scorrono
        NSGradient(colors: [rgb(0.08, 0.04, 0.25), rgb(0.45, 0.1, 0.58), rgb(0.12, 0.22, 0.6), rgb(0.05, 0.03, 0.2)])!.draw(in: box, angle: 30 + t * 25)
        NSColor(srgbRed: 1, green: 0.4, blue: 0.8, alpha: 0.25 + 0.15 * sin(t * 2)).setFill()
        oval(NSRect(x: box.midX - 4 + sin(t) * 2, y: box.midY - 2, width: 8, height: 5))
        for k in 0..<30 {
            let x = box.minX + frac(hash01(k) + t * 0.12) * box.width, y = box.minY + hash01(k + 40) * box.height
            let s = 0.25 + 0.3 * (0.5 + 0.5 * sin(t * 5 + CGFloat(k)))
            NSColor.white.setFill(); oval(NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s))
        }
    }
}

/// Mantello da eroe: parte dalle spalle e sventola all'indietro a onde.
func drawCape(at b: NSPoint, _ t: CGFloat) {
    var top: [NSPoint] = [], bottom: [NSPoint] = []
    for i in 0...8 {
        let s = CGFloat(i), wave = sin(t * 11 - s * 0.9) * 0.25 * s
        let x = b.x + 1 - s * 2.1
        top.append(P(x, b.y + 0.6 - s * 0.2 + wave))
        bottom.append(P(x - 0.25 * s, b.y - 2.4 - s * 0.55 + wave * 1.3))
    }
    rgb(0.82, 0.08, 0.12).setFill(); fillPath(top + bottom.reversed())
    rgb(1, 0.78, 0.15).setStroke()
    let hem = NSBezierPath(); hem.move(to: bottom[0]); bottom.dropFirst().forEach { hem.line(to: $0) }; hem.lineWidth = 0.35; hem.stroke()
}

/// Jetpack sulla schiena: due serbatoi, fiammate lunghe e tremolanti, sbuffi di fumo.
func drawJetpack(at b: NSPoint, _ t: CGFloat) {
    for k in 0..<6 {
        let ph = frac(t * 1.4 + CGFloat(k) / 6), r = 0.6 + ph * 1.8
        NSColor(white: 0.7, alpha: 0.5 * (1 - ph)).setFill()
        oval(NSRect(x: b.x - 2 - ph * 9 - r, y: b.y - 8 - ph * 1.5 - r, width: 2 * r, height: 2 * r))
    }
    for (n, dx): (Int, CGFloat) in [(0, -2.9), (1, -1.3)] {
        let x = b.x + dx, base = b.y - 3.6
        let len = 4.5 + sin(t * 40 + CGFloat(n) * 2) * 1.2 + hash01(Int(t * 30) * 2 + n) * 1.8
        NSColor(srgbRed: 1, green: 0.4, blue: 0.05, alpha: 0.9).setFill(); poly(P(x - 0.1, base), P(x + 1.5, base), P(x + 0.7, base - len))
        NSColor(srgbRed: 1, green: 0.95, blue: 0.45, alpha: 1).setFill(); poly(P(x + 0.3, base), P(x + 1.1, base), P(x + 0.7, base - len * 0.55))
        rgb(0.75, 0.78, 0.83).setFill(); pill(NSRect(x: x, y: base, width: 1.4, height: 4.6))
        rgb(0.85, 0.15, 0.15).setFill(); NSRect(x: x, y: base + 2.2, width: 1.4, height: 0.45).fill()
        rgb(0.3, 0.32, 0.36).setFill(); NSRect(x: x + 0.15, y: base - 0.35, width: 1.1, height: 0.5).fill()
    }
}

/// Nuvoletta temporalesca sopra la testa: pioggia continua e un fulmine con lampo circa ogni 0,8 s.
func drawStorm(over h: NSPoint, ground: CGFloat, _ t: CGFloat) {
    let c = P(h.x - 1, h.y + 5 + sin(t * 2) * 0.4)
    NSColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 0.85).setStroke()
    for k in 0..<10 {
        let ph = frac(t * 2.5 + hash01(k)), x = c.x - 3.5 + hash01(k + 9) * 7, y = c.y - 1 - ph * (c.y - 1 - ground)
        strokeLine(P(x, y), P(x - 0.3, y - 1.2), width: 0.2)
    }
    let flash = frac(t * 1.25) < 0.14
    if flash {
        let seed = Int(t * 1.25)
        var pts = [P(c.x + (hash01(seed) - 0.5) * 3, c.y - 1)]
        for k in 1...5 { pts.append(P(pts[0].x + (hash01(seed * 7 + k) - 0.5) * 3, c.y - 1 - CGFloat(k) / 5 * (c.y - 1 - ground))) }
        NSColor(srgbRed: 1, green: 0.95, blue: 0.5, alpha: 0.25).setFill(); oval(NSRect(x: c.x - 9, y: c.y - 7, width: 18, height: 14))
        NSColor(srgbRed: 1, green: 0.9, blue: 0.2, alpha: 1).setStroke()
        let bolt = NSBezierPath(); bolt.move(to: pts[0]); pts.dropFirst().forEach { bolt.line(to: $0) }
        bolt.lineWidth = 0.7; bolt.lineJoinStyle = .round; bolt.stroke()
        NSColor.white.setStroke(); bolt.lineWidth = 0.25; bolt.stroke()
    }
    (flash ? rgb(0.78, 0.78, 0.88) : rgb(0.36, 0.38, 0.46)).setFill()
    for (dx, dy, r): (CGFloat, CGFloat, CGFloat) in [(-2.6, 0, 1.6), (-0.9, 0.7, 2.1), (1.1, 0.5, 1.9), (2.7, -0.1, 1.4)] {
        oval(NSRect(x: c.x + dx - r, y: c.y + dy - r, width: 2 * r, height: 2 * r))
    }
    pill(NSRect(x: c.x - 4.2, y: c.y - 1.6, width: 8.4, height: 2))
}

/// Occhi laser: raggio rosso che pulsa e spazzola su e giù attraversando tutta la barra.
func drawLaser(from e: NSPoint, _ t: CGFloat) {
    let a = sin(t * 2.5) * 0.06, pulse = 0.75 + 0.25 * sin(t * 30)
    let end = P(e.x + cos(a) * 900, e.y + sin(a) * 900)
    NSColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 0.3).setStroke(); strokeLine(e, end, width: 2.6 * pulse)
    NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 0.95).setStroke(); strokeLine(e, end, width: 0.9 * pulse)
    NSColor.white.setStroke(); strokeLine(e, end, width: 0.3)
    NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 0.4).setFill(); oval(NSRect(x: e.x - 2, y: e.y - 2, width: 4, height: 4))
    NSColor.white.setFill(); sparkle(e, 1.6 * pulse)
}

/// Cuffie da DJ: archetto sopra la testa, padiglione con luci arcobaleno, note che volano via.
func drawHeadphones(top h: NSPoint, eye e: NSPoint, _ t: CGFloat) {
    let cup = P(e.x - 2.1, e.y - 0.1)
    let band = NSBezierPath(); band.move(to: P(cup.x, cup.y + 1))
    band.curve(to: P(h.x + 1.6, h.y - 1.2), controlPoint1: P(cup.x - 0.6, h.y + 1.8), controlPoint2: P(h.x + 1.4, h.y + 1.6))
    rgb(0.15, 0.15, 0.18).setStroke(); band.lineWidth = 0.55; band.lineCapStyle = .round; band.stroke()
    rgb(0.1, 0.1, 0.12).setFill(); oval(NSRect(x: cup.x - 0.9, y: cup.y - 1.2, width: 1.8, height: 2.4))
    let ring = NSBezierPath(ovalIn: NSRect(x: cup.x - 0.6, y: cup.y - 0.85, width: 1.2, height: 1.7))
    NSColor(hue: frac(t * 0.8), saturation: 0.9, brightness: 1, alpha: 1).setStroke(); ring.lineWidth = 0.3; ring.stroke()
    for k in 0..<4 {
        let ph = frac(t * 0.7 + CGFloat(k) / 4)
        let at = P(cup.x - 1.5 - ph * 9, cup.y + 1 + ph * 9 + sin(ph * 12) * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 3.6, weight: .bold),
                                                    .foregroundColor: NSColor(hue: frac(CGFloat(k) / 4 + t * 0.3), saturation: 0.8, brightness: 1, alpha: 1 - ph)]
        ((k % 2 == 0 ? "♪" : "♫") as NSString).draw(at: at, withAttributes: attrs)
    }
}

/// Dinosauro rivolto a destra dentro un rettangolo 14x12 (cappelli possono sporgere sopra).
/// `phase`: fase continua della corsa (nil = in aria); `t`: orologio per le animazioni di skin e accessori.
func drawDino(_ rect: CGRect, phase: CGFloat?, wings: Bool, flap: CGFloat, look: Look, time t: CGFloat = 0) {
    let ground = rect.minY
    var lift = phase.map { abs(sin($0)) * 0.35 } ?? 0 // il corpo molleggia a ogni passo, i piedi no
    if look.costume == .ghost { lift += 0.8 + sin(t * 3) * 0.8 } // il fantasma fluttua
    if look.gadget == .headphones { lift += abs(sin(t * 7)) * 0.5 } // balla a tempo
    let p = rect.offsetBy(dx: 0, dy: lift)
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: p.minX + x, y: p.minY + y) }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: p.minX + x, y: p.minY + y, width: w, height: h) }
    let skin = look.skinColor, accent = look.accentColor
    let f = look.species.fit
    let ctx = NSGraphicsContext.current!.cgContext

    // --- dietro al dino: copie fantasma, scia arcobaleno, pianeti dietro, mantello
    if look.costume == .ghost {
        var echo = look; echo.costume = nil; echo.gadget = nil; echo.skin = [0.75, 0.9, 1]; echo.accent = [0.75, 0.9, 1]
        for k in (1...3).reversed() {
            ctx.saveGState(); ctx.setAlpha(0.3 - CGFloat(k) * 0.07); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            drawDino(rect.offsetBy(dx: -CGFloat(k) * 4.5, dy: 0.8 + sin(t * 3 - CGFloat(k) * 0.6) * 0.8),
                     phase: phase.map { $0 - CGFloat(k) * 0.5 }, wings: false, flap: 0, look: echo)
            ctx.endTransparencyLayer(); ctx.restoreGState()
        }
    }
    if look.costume == .rainbow {
        for i in 0..<6 {
            func y(_ x: CGFloat) -> CGFloat { p.minY + 6.5 + (CGFloat(i) - 2.5) * 0.9 + sin(t * 9 + x * 0.35) * 1.3 }
            for s in 0..<10 {
                let x0 = p.minX + 2 - CGFloat(s) * 4, x1 = x0 - 4
                NSColor(hue: CGFloat(i) / 6, saturation: 0.85, brightness: 1, alpha: 0.9 * (1 - CGFloat(s) / 10)).setStroke()
                strokeLine(P(x0, y(x0)), P(x1, y(x1)), width: 0.95)
            }
        }
        NSColor.white.setFill()
        for k in 0..<5 { let ph = frac(t * 1.5 + CGFloat(k) / 5); sparkle(P(p.minX - ph * 36, p.minY + 4 + hash01(k) * 6), 0.9 * (1 - ph)) }
    }
    func orbit(front: Bool) { // galassia: tre pianeti che girano attorno al dino, davanti e dietro
        for k in 0..<3 {
            let a = t * 2.2 + CGFloat(k) * 2.1
            guard (sin(a) < 0) == front else { continue }
            let c = P(p.minX + 7 + cos(a) * 11, p.minY + 6.5 + sin(a) * 4.5), s = [1.6, 1.1, 1.3][k]
            [rgb(1, 0.6, 0.2), rgb(0.3, 0.9, 1), rgb(1, 0.4, 0.8)][k].setFill(); oval(NSRect(x: c.x - s, y: c.y - s, width: 2 * s, height: 2 * s))
            if k == 0 {
                let ring = NSBezierPath(ovalIn: NSRect(x: c.x - 2.6, y: c.y - 0.6, width: 5.2, height: 1.2))
                rgb(1, 0.85, 0.5).setStroke(); ring.lineWidth = 0.3; ring.stroke()
            }
        }
    }
    if look.costume == .galaxy { orbit(front: false) }
    if look.gadget == .cape { drawCape(at: pt(f.back.x, f.back.y), t) }

    // --- corpo: con una skin, si disegna in un livello a parte e poi ci si dipinge sopra la texture
    if look.costume != nil {
        ctx.saveGState()
        if look.costume == .ghost { ctx.setAlpha(0.78) }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    }

    // zampe (anca, lunghezza, spessore, sfasamento): bipede una coppia, quadrupedi posteriore e anteriore in controfase
    let legs: [(hip: NSPoint, len: CGFloat, w: CGFloat, off: CGFloat)] = switch look.species {
    case .rex: [(P(6.2, 4.6), 5, 1.6, 0)]
    case .triceratops: [(P(3.8, 4.2), 3.8, 2, 0), (P(8.6, 4.2), 3.8, 2, .pi)]
    case .stego: [(P(4.5, 5), 4.6, 1.9, 0), (P(9, 4.4), 4, 1.8, .pi)]
    case .brachio: [(P(3.3, 5), 4.6, 2, 0), (P(7.6, 5.6), 5, 2, .pi)]
    }
    func drawLegs(far: Bool) { // il lato lontano è più scuro, un po' spostato e in controfase
        (far ? skin.blended(withFraction: 0.3, of: .black)! : skin).setStroke()
        for l in legs {
            drawLeg(hip: pt(l.hip.x + (far ? 0.8 : 0), l.hip.y), ground: ground, length: l.len, width: l.w * (far ? 0.9 : 1),
                    phase: phase.map { $0 + l.off + (far ? .pi : 0) })
        }
    }
    drawLegs(far: true)

    switch look.species {
    case .rex:
        accent.setFill()
        for sx: CGFloat in [4, 6.5, 9] { poly(pt(sx, 8), pt(sx + 2, 8), pt(sx + 1, 10.5)) } // creste
        skin.setFill()
        poly(pt(0, 7.5), pt(5, 8), pt(5, 4.5)); oval(r(3, 3, 8.5, 6)); pill(r(9, 5, 2.5, 5)); pill(r(9, 8, 5, 4))
    case .triceratops:
        accent.setFill() // gorgiera: ventaglio dietro la testa
        let frill = NSBezierPath(); let fc = pt(10.6, 6)
        frill.move(to: fc); frill.appendArc(withCenter: fc, radius: 3.8, startAngle: 60, endAngle: 200); frill.close(); frill.fill()
        skin.setFill()
        poly(pt(0, 5.5), pt(3, 6.8), pt(3, 3.8)); oval(r(1.5, 2.3, 9.5, 6.5)); pill(r(9.3, 4, 4.7, 3.6))
        NSColor(white: 0.95, alpha: 1).setFill() // corna
        poly(pt(11, 7.2), pt(13.9, 9.6), pt(11.9, 7)); poly(pt(13.2, 6.9), pt(14, 8.6), pt(13.9, 6.6))
    case .stego:
        accent.setFill()
        for (sx, h): (CGFloat, CGFloat) in [(3, 3), (5.3, 3.8), (7.6, 3.2)] { poly(pt(sx, 7.5), pt(sx + 1.1, 7.5 + h), pt(sx + 2.2, 7.5)) } // placche
        poly(pt(0.4, 5.8), pt(0.1, 7.8), pt(1.3, 6)) // spuntone sulla coda
        skin.setFill()
        poly(pt(0, 5.5), pt(3, 6.8), pt(3, 4.2)); oval(r(2, 3, 9.5, 6)); pill(r(9.6, 3.8, 2.6, 3)); pill(r(10.6, 3.6, 3.4, 2.8))
    case .brachio:
        skin.setFill()
        poly(pt(0, 6), pt(2.5, 7), pt(2.5, 5)); oval(r(1.5, 3, 8, 5.5))
        poly(pt(7.5, 6.2), pt(9.3, 5.8), pt(12.4, 10), pt(10.9, 10.8)) // collo lungo
        pill(r(10.5, 9.6, 3.5, 2.4))
        accent.setFill()
        for (sx, sy): (CGFloat, CGFloat) in [(3.5, 6), (5.5, 7), (6.5, 5)] { oval(r(sx, sy, 1.3, 1)) } // macchie
    }

    drawLegs(far: false)
    if look.species == .rex { // braccini: spalla, gomito, mano
        let swing = phase.map { sin($0) * 0.3 } ?? 0.3
        let arm = NSBezierPath(); arm.move(to: pt(10, 6.3)); arm.line(to: pt(10.7, 5.2 + swing)); arm.line(to: pt(11.6, 5.7 + swing))
        skin.setStroke(); arm.lineWidth = 0.7; arm.lineCapStyle = .round; arm.lineJoinStyle = .round; arm.stroke()
    }

    if let costume = look.costume { // texture solo dove c'è già il corpo (sourceAtop), poi si chiude il livello
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current!.compositingOperation = .sourceAtop
        drawCostumeTexture(costume, in: NSRect(x: p.minX - 3, y: ground - 1, width: 20, height: 16), t)
        NSGraphicsContext.restoreGraphicsState()
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }

    let eye = pt(f.eye.x, f.eye.y), head = pt(f.hat.x, f.hat.y), back = pt(f.back.x, f.back.y)
    local(eye, scale: f.eyeScale) {
        NSColor.white.setFill(); oval(NSRect(x: -0.9, y: -0.9, width: 1.8, height: 1.8))
        NSColor.black.setFill(); oval(NSRect(x: -0.1, y: -0.4, width: 0.9, height: 0.9))
    }
    if look.costume == .robot { // visiera rossa con il punto che scansiona, antenna lampeggiante, scintille
        local(eye, scale: f.eyeScale) {
            NSColor(srgbRed: 1, green: 0.1, blue: 0.1, alpha: 0.35).setFill(); oval(NSRect(x: -2.4, y: -1.4, width: 4.8, height: 2.8))
            rgb(0.85, 0.05, 0.05).setFill(); pill(NSRect(x: -1.7, y: -0.6, width: 3.4, height: 1.2))
            NSColor.white.setFill(); oval(NSRect(x: -1.4 + (sin(t * 6) + 1) * 1.2, y: -0.35, width: 0.7, height: 0.7))
        }
        rgb(0.5, 0.55, 0.62).setStroke(); strokeLine(P(head.x - 0.5, head.y - 0.3), P(head.x - 1.2, head.y + 2.4), width: 0.3)
        (frac(t * 2) < 0.5 ? rgb(1, 0.15, 0.15) : rgb(0.4, 0.05, 0.05)).setFill()
        oval(NSRect(x: head.x - 1.75, y: head.y + 2.1, width: 1.1, height: 1.1))
        if frac(t * 1.7) < 0.25 {
            NSColor(srgbRed: 0.6, green: 0.9, blue: 1, alpha: 1).setStroke()
            let s = P(back.x - 2 + hash01(Int(t * 1.7)) * 4, back.y - 1)
            strokeLine(s, P(s.x + 0.8, s.y + 1), P(s.x + 0.2, s.y + 1.6), P(s.x + 1.2, s.y + 2.8), width: 0.3)
        }
    }
    drawNeckwear(look.neck, at: pt(f.neck.x, f.neck.y), angle: f.neckAngle, width: f.neckWidth)
    local(eye, scale: f.eyeScale) { drawGlasses(look.glasses) }
    if look.gadget == .headphones { drawHeadphones(top: head, eye: eye, t) }
    local(head, angle: f.hatAngle, scale: f.hatScale) { drawHat(look.hat) }

    // --- davanti: accessori speciali ed effetti delle skin
    switch look.gadget {
    case .jetpack: drawJetpack(at: back, t)
    case .storm: drawStorm(over: head, ground: ground, t)
    case .laser: drawLaser(from: eye, t)
    default: break
    }
    switch look.costume {
    case .inferno: // fiamme che salgono dalla schiena e braci
        for k in 0..<16 {
            let ph = frac(t * 1.6 + hash01(k)), s = sin(ph * .pi) * 2.2 + 0.3 // nasce piccola, cresce, si spegne
            let x = p.minX + 1 + hash01(k + 20) * 11 + sin(t * 8 + CGFloat(k)) * 0.5 - ph * 3, y = p.minY + 7 + ph * 8
            NSColor(srgbRed: 1, green: 0.9 - ph * 0.7, blue: 0.2 * (1 - ph), alpha: 1 - ph).setFill()
            oval(NSRect(x: x - s / 2, y: y - s / 2, width: s, height: s)) // goccia di fiamma: tondo sotto, punta sopra
            poly(P(x - s / 2, y), P(x + sin(t * 10 + CGFloat(k)) * s * 0.3, y + s * 1.4), P(x + s / 2, y))
        }
    case .galaxy:
        orbit(front: true)
        for k in 0..<6 { // stelline che si accendono attorno
            NSColor.white.withAlphaComponent(max(0, sin(t * 4 + CGFloat(k) * 1.7))).setFill()
            sparkle(P(p.minX - 2 + hash01(k + 60) * 18, p.minY + hash01(k + 70) * 15), 0.9)
        }
    default: break
    }

    if wings {
        NSColor(srgbRed: 0.88, green: 0.82, blue: 1, alpha: 1).setFill()
        poly(pt(4, 7.5), pt(0.5, 10 + flap * 2.5), pt(8.5, 8))
    }
}

/// Anteprima grande e animata del dinosauro nel menù.
final class DinoPreview: NSView {
    var look = Look() { didSet { needsDisplay = true } }
    var time: CGFloat = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let s = scenes[0]
        NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14).addClip()
        NSGradient(starting: s.skyBottom, ending: s.skyTop)!.draw(in: bounds, angle: 90)
        let k = min(bounds.width / 26, bounds.height / 23) // unità del gioco → punti; alto abbastanza per la nuvola temporale
        let tr = NSAffineTransform(); tr.translateX(by: (bounds.width - 26 * k) / 2, yBy: 0); tr.scale(by: k); tr.concat()
        drawBack(.hills, 13, 0, s)
        s.mid.setFill(); drawFern(2.5, size: 5); drawPalm(21, height: 11)
        s.ground.setFill(); NSRect(x: -20, y: -5, width: 70, height: groundY + 5).fill()
        drawDino(CGRect(x: 6, y: groundY, width: 14, height: 12), phase: time * 2 * .pi * 2.2, wings: false, flap: 0, look: look, time: time)
    }
}

func drawText(_ text: String, size: CGFloat, centerX: CGFloat? = nil, right: CGFloat = 0, y: CGFloat, alpha: CGFloat = 1) {
    let attrs: [NSAttributedString.Key: Any] = [
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
    ]
    let s = (text as NSString).size(withAttributes: attrs)
    let x = centerX.map { $0 - s.width / 2 } ?? right - s.width
    NSColor.black.withAlphaComponent(0.45 * alpha).setFill() // fondo scuro: leggibile anche col cielo chiaro
    pill(NSRect(x: x - 4, y: y - 0.5, width: s.width + 8, height: s.height + 1))
    (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
}

final class GameView: NSView {
    var game = Game()
    var best = 0
    var look = Look()
    var inMenu = true // finché si personalizza il dino nella finestra il gioco è fermo

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = .direct
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) {
        // col fiore di fuoco la metà destra della barra spara, la sinistra salta
        let x = event.touches(matching: .began, in: self).first?.location(in: self).x ?? 0
        if game.active[.fire] != nil && !game.paused && !inMenu && x > visibleRect.midX { game.shoot() } else { tap() }
    }

    func tap() {
        guard !inMenu else { return }
        if game.over { game = Game() } else if game.paused { game.paused = false } else { game.jump() }
    }

    func togglePause() { if !game.over && !inMenu { game.paused.toggle() } }

    func tick(_ dt: CGFloat) {
        if !inMenu { game.step(dt, width: visibleRect.maxX) }
        best = max(best, game.score)
        needsDisplay = true
    }

    /// Elementi ripetuti ogni `period` punti che scorrono a `parallax` volte la velocità del terreno.
    func layer(_ parallax: CGFloat, _ period: CGFloat, _ draw: (CGFloat, Int) -> Void) {
        let off = game.distance * parallax
        let first = Int(off / period)
        for i in first - 1...first + Int(visibleRect.maxX / period) + 1 { draw(CGFloat(i) * period - off, i) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = visibleRect.maxX // la vista può essere più larga della parte visibile
        let d = game.distance
        let phase = d / sceneLength, n = Int(phase), t = phase - CGFloat(n)
        let cur = scenes[n % scenes.count], next = scenes[(n + 1) % scenes.count]
        let fade = max(0, (t - 0.85) / 0.15) // l'ultimo 15% di ogni ambientazione sfuma nella successiva
        let s = cur.blended(with: next, fade)

        NSGradient(starting: s.skyBottom, ending: s.skyTop)!.draw(in: bounds, angle: 90)

        // stelle che brillano, sole o luna
        layer(0.02, 19) { x, i in
            let a = s.night * (0.55 + 0.45 * sin(d / 25 + CGFloat(i)))
            NSColor.white.withAlphaComponent(a).setFill()
            NSRect(x: x + hash01(i) * 19, y: 8 + hash01(i + 99) * 21, width: 0.8, height: 0.8).fill()
        }
        let sky = NSPoint(x: w * 0.62, y: 21)
        NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 0.25 * (1 - s.night)).setFill()
        NSBezierPath(ovalIn: NSRect(x: sky.x - 7, y: sky.y - 7, width: 14, height: 14)).fill()
        NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1 - s.night).setFill()
        NSBezierPath(ovalIn: NSRect(x: sky.x - 4.5, y: sky.y - 4.5, width: 9, height: 9)).fill()
        NSColor(white: 0.92, alpha: s.night).setFill()
        NSBezierPath(ovalIn: NSRect(x: sky.x - 4, y: sky.y - 4, width: 8, height: 8)).fill()
        NSColor(white: 0.75, alpha: s.night).setFill()
        NSBezierPath(ovalIn: NSRect(x: sky.x - 1.5, y: sky.y, width: 2, height: 2)).fill()

        scenery(cur, s, alpha: 1 - fade)
        scenery(next, s, alpha: fade)

        // terreno: erba in cima, sassolini che scorrono
        s.ground.setFill(); NSRect(x: 0, y: 0, width: bounds.width, height: groundY).fill()
        s.mid.setFill(); NSRect(x: 0, y: groundY - 0.6, width: bounds.width, height: 0.6).fill()
        s.ground.blended(withFraction: 0.35, of: .black)!.setFill()
        layer(1, 23) { x, _ in NSRect(x: x, y: 1, width: 2, height: 1).fill() }

        for it in game.items {
            let r = it.rect.offsetBy(dx: 0, dy: sin(d / 12)) // galleggia
            NSColor.white.withAlphaComponent(0.35).setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5)).fill()
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 7)]
            let sz = (it.power.emoji as NSString).size(withAttributes: attrs)
            (it.power.emoji as NSString).draw(at: NSPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
        }

        // Il contrasto che si vede è di luminosità: più il cielo è chiaro, più il cactus diventa verde scuro
        let horizon = s.skyBottom.usingColorSpace(.sRGB)!
        let luma: CGFloat = 0.3 * horizon.redComponent + 0.59 * horizon.greenComponent + 0.11 * horizon.blueComponent
        let skyLight = max(0, min(1, (luma - 0.4) / 0.3))
        // contorno quasi nero di 1 punto (la stessa sagoma spostata tutto attorno)
        rgb(0.02, 0.12, 0.04).setFill()
        for o in game.obstacles {
            for (dx, dy): (CGFloat, CGFloat) in [(-1, 0), (1, 0), (0, 1), (-0.7, 0.7), (0.7, 0.7), (-0.7, -0.7), (0.7, -0.7)] {
                drawCactus(o.offsetBy(dx: dx, dy: dy))
            }
        }
        rgb(0.25, 0.68, 0.3).blended(withFraction: skyLight * 0.55, of: rgb(0.03, 0.3, 0.1))!.setFill()
        game.obstacles.forEach(drawCactus)

        let now = CGFloat(CACurrentMediaTime()) // orologio delle animazioni (monete, skin, accessori)
        for c in game.coins { // monete che girano su se stesse
            let r: CGFloat = 2.1, w = max(0.35, abs(cos(now * 4 + c.x * 0.04))) * r
            rgb(0.72, 0.48, 0.05).setFill(); oval(NSRect(x: c.x - w, y: c.y - r, width: 2 * w, height: 2 * r))
            rgb(1, 0.82, 0.2).setFill(); oval(NSRect(x: c.x - w * 0.78, y: c.y - r * 0.78, width: 1.56 * w, height: 1.56 * r))
            NSColor.white.withAlphaComponent(0.7).setFill(); oval(NSRect(x: c.x - w * 0.45, y: c.y + r * 0.15, width: 0.5 * w, height: 0.6 * r))
        }
        for sp in game.sparkles { // moneta presa: stellina dorata che sale e svanisce
            let k = sp.age / 0.45
            NSColor(srgbRed: 1, green: 0.9, blue: 0.4, alpha: 1 - k).setFill(); sparkle(sp.at, 1 + k * 3)
        }

        let p = game.playerRect
        // fase del passo legata alla distanza: più veloce corre, più veloci le zampe (~4-5 passi al secondo).
        // Disegnato in scala dall'angolo in basso a sinistra: con la bistecca cresce fino a 1,5x.
        local(p.origin, scale: game.giant) {
            drawDino(CGRect(x: 0, y: 0, width: 14, height: 12), phase: game.playerY > 0 ? nil : d * 0.16,
                     wings: game.active[.wings] != nil, flap: sin(d / 4), look: look, time: now)
        }
        if let left = game.active[.roar] { // ruggito: onda d'urto bianca che parte dal dino e attraversa la barra
            let k = 1 - left / Power.roar.duration, r = 8 + k * 380
            let wave = NSBezierPath(ovalIn: NSRect(x: p.midX - r, y: p.midY - r, width: 2 * r, height: 2 * r))
            NSColor.white.withAlphaComponent(0.85 * (1 - k)).setStroke(); wave.lineWidth = 3 * (1 - k) + 0.5; wave.stroke()
        }
        if let left = game.active[.shield], left > 2 || Int(left * 8) % 2 == 0 { // lampeggia quando sta per finire
            let bubble = NSBezierPath(ovalIn: p.insetBy(dx: -2.5, dy: -1.5))
            NSColor.cyan.withAlphaComponent(0.2).setFill(); bubble.fill()
            NSColor.cyan.withAlphaComponent(0.8).setStroke(); bubble.lineWidth = 0.7; bubble.stroke()
        }

        // cactus spaccati: lampo arancione che si allarga e schegge verdi che volano via ricadendo
        for b in game.bursts {
            let k = b.age / 0.4
            let flash = 1.5 + k * 5 // lampo giallo che si spegne in fretta
            NSColor(srgbRed: 1, green: 0.9, blue: 0.4, alpha: (1 - k) * (1 - k)).setFill()
            oval(NSRect(x: b.at.x - flash, y: b.at.y - flash, width: 2 * flash, height: 2 * flash))
            let r = 2 + k * 9 // onda d'urto arancione
            let ring = NSBezierPath(ovalIn: NSRect(x: b.at.x - r, y: b.at.y - r, width: 2 * r, height: 2 * r))
            NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 1 - k).setStroke(); ring.lineWidth = 1.4 * (1 - k) + 0.2; ring.stroke()
            rgb(0.15, 0.55, 0.2).withAlphaComponent(1 - k).setFill() // schegge di cactus che ricadono
            for j in 0..<6 {
                let a = CGFloat(j) * .pi / 3 + 0.4
                oval(NSRect(x: b.at.x + cos(a) * k * 11 - 0.8, y: b.at.y + sin(a) * k * 11 - k * k * 8 - 0.8, width: 1.6, height: 1.6))
            }
        }
        // palle di fuoco: scia, fiamma arancione, cuore giallo che pulsa
        for f in game.fireballs {
            NSColor(srgbRed: 1, green: 0.45, blue: 0.1, alpha: 0.4).setFill(); oval(NSRect(x: f.x - 5, y: f.y - 1.2, width: 3.2, height: 2.4))
            rgb(1, 0.42, 0.08).setFill(); oval(NSRect(x: f.x - 2.3, y: f.y - 2.3, width: 4.6, height: 4.6))
            let c = 1.1 + 0.25 * sin(d + f.x)
            rgb(1, 0.9, 0.35).setFill(); oval(NSRect(x: f.x - c, y: f.y - c, width: 2 * c, height: 2 * c))
        }

        if let left = game.active[.slow] { // rallentatore: bagliore azzurro pulsante ai bordi, entra ed esce in dissolvenza
            let k = min(1, left / 0.6, (Power.slow.duration - left) / 0.3) * (0.75 + 0.25 * sin(d / 5))
            let glow = NSColor(srgbRed: 0.4, green: 0.85, blue: 1, alpha: 0.9 * k)
            let edge = NSGradient(starting: glow, ending: glow.withAlphaComponent(0))!
            edge.draw(in: NSRect(x: 0, y: 0, width: 90, height: bounds.height), angle: 0)
            edge.draw(in: NSRect(x: w - 90, y: 0, width: 90, height: bounds.height), angle: 180)
            edge.draw(in: NSRect(x: 0, y: bounds.height - 8, width: w, height: 8), angle: 270)
            edge.draw(in: NSRect(x: 0, y: 0, width: w, height: 6), angle: 90)
            let border = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: w - 1.5, height: bounds.height - 1.5), xRadius: 4, yRadius: 4)
            NSColor(srgbRed: 0.75, green: 0.95, blue: 1, alpha: k).setStroke(); border.lineWidth = 1.5; border.stroke()
            NSColor(srgbRed: 0.3, green: 0.5, blue: 0.95, alpha: 0.12 * k).setFill(); bounds.fill() // velo blu su tutto
        }

        if inMenu {
            drawText("Personalizza il tuo dino nella finestra, poi premi Gioca! 🦖", size: 11, centerX: w / 2 + 30, y: 15)
        } else if game.over {
            drawText("ESTINTO!  \(game.score)  ·  tocca per ricominciare", size: 11, centerX: w / 2, y: 15)
        } else {
            let powers = Power.allCases.compactMap { pw -> String? in // uovo senza secondi (dura finché serve), ruggito istantaneo
                guard let left = game.active[pw], pw != .roar else { return nil }
                return pw == .egg ? pw.emoji : "\(pw.emoji)\(Int(left.rounded(.up)))"
            }
            // sulla barra il record della sessione; quello assoluto è nella finestra principale
            drawText((powers + ["🪙\(game.coinsTaken)", "\(game.score)   record \(best)"]).joined(separator: "  "), size: 11, right: w - 8, y: 15)
            if game.paused {
                NSColor.black.withAlphaComponent(0.35).setFill(); bounds.fill()
                drawText("⏸ PAUSA  ·  Esc o tocca per riprendere", size: 11, centerX: w / 2, y: 9)
            } else if let n = game.notice {
                drawText(n.text, size: 11, centerX: w / 2, y: 15)
            } else if let left = game.active[.fire], Power.fire.duration - left < 2.5 { // appena preso: spiega come si spara
                drawText("🌺 Fiore di fuoco: tocca a destra (o →) per sparare", size: 10, centerX: w / 2, y: 16)
            } else if t < 0.1 {
                drawText(s.name, size: 10, centerX: w / 2, y: 16, alpha: min(1, (0.1 - t) / 0.03))
            }
        }
    }

    /// Sfondo lontano, pterodattili, elementi vicini e meteo di un'ambientazione, con i colori `s`.
    /// Durante il cambio di ambientazione viene chiamato per entrambe, con trasparenza opposta.
    func scenery(_ sc: Scene, _ s: Scene, alpha: CGFloat) {
        guard alpha > 0.01, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState(); ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { ctx.endTransparencyLayer(); ctx.restoreGState() }
        let w = visibleRect.maxX, d = game.distance

        if sc.back == .sea { // mare con riflessi che scorrono
            rgb(0.08, 0.32, 0.5).blended(withFraction: 0.35, of: s.skyBottom)!.setFill()
            NSRect(x: 0, y: groundY, width: bounds.width, height: 6).fill()
            NSColor.white.withAlphaComponent(0.35).setFill()
            layer(0.2, 17) { x, i in NSRect(x: x + hash01(i) * 10, y: groundY + 1 + hash01(i + 9) * 4, width: 3, height: 0.4).fill() }
        }
        layer(0.12, 230) { x, i in drawBack(sc.back, x + hash01(i) * 80, i, s) }
        s.far.blended(withFraction: 0.5, of: .black)!.setFill()
        layer(0.3, 330) { x, i in
            guard hash01(i + 5) > 0.35 else { return }
            drawPtero(x + hash01(i) * 150, 20 + hash01(i + 3) * 6, flap: sin(d / 7 + CGFloat(i)))
        }
        layer(0.45, 55) { x, i in drawProps(sc.props, x + hash01(i + 4) * 20, i, s) }

        // coordinate che si ripetono su tutta la larghezza mentre il mondo scorre
        func wrap(_ v: CGFloat, _ span: CGFloat) -> CGFloat { let m = v.truncatingRemainder(dividingBy: span); return m < 0 ? m + span : m }
        switch sc.weather {
        case .clear: break
        case .snow:
            NSColor.white.withAlphaComponent(0.85).setFill()
            for k in 0..<45 {
                let x = wrap(hash01(k) * (w + 20) - d * 0.3, w + 20) - 10, y = 32 - wrap(hash01(k + 50) * 34 + d * 0.08, 34)
                oval(NSRect(x: x, y: y, width: 0.9, height: 0.9))
            }
        case .fog:
            NSGradient(colors: [NSColor(white: 1, alpha: 0), NSColor(white: 1, alpha: 0.3), NSColor(white: 1, alpha: 0)])!
                .draw(in: NSRect(x: 0, y: groundY, width: bounds.width, height: 14), angle: 90)
        case .fireflies:
            for k in 0..<16 {
                let x = wrap(hash01(k) * (w + 20) - d * 0.2, w + 20) - 10 + sin(d / 20 + CGFloat(k)) * 6
                let y = 5 + hash01(k + 30) * 16 + cos(d / 15 + CGFloat(k) * 2) * 2
                let a = 0.5 + 0.5 * sin(d / 6 + CGFloat(k) * 3)
                NSColor(srgbRed: 1, green: 0.95, blue: 0.4, alpha: 0.25 * a).setFill()
                oval(NSRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
                NSColor(srgbRed: 1, green: 0.95, blue: 0.4, alpha: a).setFill()
                oval(NSRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
            }
        }
    }
}

/// Icona dell'app: 1024x1024 PNG nello stile delle icone macOS (riquadro arrotondato con ombra e riflesso).
/// Il dinosauro col casco da esploratore salta un cactus davanti a un grande sole al tramonto.
@MainActor func renderIcon(to path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let box = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: box, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState() // ombra sotto il riquadro, come le icone di sistema
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set(); NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // cielo al tramonto e grande sole con alone
    NSGradient(colors: [rgb(1, 0.8, 0.42), rgb(0.97, 0.5, 0.33), rgb(0.55, 0.22, 0.48), rgb(0.17, 0.1, 0.33)],
               atLocations: [0, 0.32, 0.68, 1], colorSpace: .sRGB)!.draw(in: box, angle: 90)
    let sun = NSPoint(x: 700, y: 640)
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.9, blue: 0.55, alpha: 0.75), ending: NSColor(srgbRed: 1, green: 0.6, blue: 0.3, alpha: 0))!
        .draw(fromCenter: sun, radius: 150, toCenter: sun, radius: 420, options: [])
    NSGradient(starting: rgb(1, 0.95, 0.65), ending: rgb(1, 0.72, 0.35))!.draw(in: NSBezierPath(ovalIn: NSRect(x: sun.x - 165, y: sun.y - 165, width: 330, height: 330)), angle: -90)

    // il resto in unità di gioco: 32 unità di lato, suolo a y = 9
    NSGraphicsContext.saveGraphicsState()
    let tr = NSAffineTransform(); tr.scale(by: 32); tr.translateX(by: 0, yBy: 6); tr.concat()
    rgb(0.28, 0.12, 0.27).setFill()
    oval(NSRect(x: -6, y: groundY - 3, width: 22, height: 7)) // colline lontane
    drawVolcano(22.5, height: 8.5, halfWidth: 8, rock: rgb(0.36, 0.15, 0.3), smoke: false) // in controluce davanti al sole
    rgb(0.12, 0.2, 0.14).setFill()
    drawFern(7, size: 4.5); drawFern(18.5, size: 3.5)
    NSGradient(starting: rgb(0.55, 0.36, 0.18), ending: rgb(0.36, 0.22, 0.1))!.draw(in: NSRect(x: 0, y: -10, width: 32, height: groundY + 10), angle: -90)
    rgb(0.32, 0.6, 0.22).setFill(); NSRect(x: 0, y: groundY - 0.5, width: 32, height: 0.5).fill() // erba
    rgb(0.3, 0.72, 0.32).setFill(); drawCactus(CGRect(x: 21.5, y: groundY, width: 6.5, height: 10.5))
    NSColor.white.withAlphaComponent(0.25).setFill(); pill(NSRect(x: 23.95, y: groundY + 1.5, width: 0.6, height: 7.5)) // riflesso sul cactus
    NSColor.black.withAlphaComponent(0.22).setFill(); oval(NSRect(x: 6.5, y: groundY - 0.7, width: 12, height: 1.4)) // ombra del salto

    NSColor.white.withAlphaComponent(0.65).setStroke() // scie di velocità
    for (y, len): (CGFloat, CGFloat) in [(12.8, 1.6), (11.1, 2.4), (9.4, 1.2)] { strokeLine(P(5.6 - len, y), P(5.6, y), width: 0.45) }
    local(P(13.6, groundY + 2.6), angle: 9, scale: 1.12) { // in salto, un po' inclinato in avanti verso l'alto
        drawDino(CGRect(x: -7, y: 0, width: 14, height: 12), phase: nil, wings: false, flap: 0, look: Look(hat: .safari))
    }
    NSGraphicsContext.restoreGraphicsState()

    // riflesso morbido in alto e bordo sottile, per dare volume
    NSGradient(starting: NSColor.white.withAlphaComponent(0), ending: NSColor.white.withAlphaComponent(0.2))! // sfuma verso il basso, niente stacchi
        .draw(in: NSRect(x: box.minX, y: box.midY + 120, width: box.width, height: box.height / 2 - 120), angle: 90)
    NSGraphicsContext.restoreGraphicsState()
    NSColor.black.withAlphaComponent(0.25).setStroke(); shape.lineWidth = 3; shape.stroke()

    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// MARK: - Musica: brano chiptune originale "giungla", sintetizzato all'avvio e ripetuto in loop

let songRate = 44100.0
let bpm = 132.0

// Melodia in La minore pentatonico, una battuta per riga (16 sedicesimi): "." prolunga la nota, "-" è silenzio.
// Parte A: Lam | Fa | Sol | Lam — parte B: Rem | Lam | Sol | Mi (il Sol# riporta all'inizio del loop).
let melody = [
    "A4 . . C5 . . D5 . E5 . . . G5 . E5 .",
    "D5 . C5 . A4 . . . C5 . D5 . C5 . A4 .",
    "G4 . . A4 . . C5 . D5 . . . E5 . D5 .",
    "C5 . A4 . . . - - A4 C5 D5 E5 G5 . A5 .",
    "D5 . F5 . A5 . . . G5 . F5 . D5 . . .",
    "E5 . . . C5 . A4 . C5 . E5 . A5 . . .",
    "G5 . E5 . D5 . . . B4 . D5 . G5 . . .",
    "G#5 . . . E5 . . . B4 . . . - - - -",
]
let bassRoots = ["A2", "F2", "G2", "A2", "D2", "A2", "G2", "E2"]
let bassPattern: [Int?] = [0, nil, nil, 0, nil, nil, 12, nil, 0, nil, nil, 0, nil, nil, 7, nil] // semitoni sopra la radice
// Percussioni tribali: K cassa, T tamburo basso, t tamburo alto, s shaker
let drumsA = "K-st-sT-K-stT-ts", drumsB = "KstsTsttKstsTTtt"
// Accordi di ogni battuta (per arpeggio, tappeto e campanelle): Lam Fa Sol Lam Rem Lam Sol Mi
let chords = [["A3", "C4", "E4"], ["F3", "A3", "C4"], ["G3", "B3", "D4"], ["A3", "C4", "E4"],
              ["D3", "F3", "A3"], ["A3", "C4", "E4"], ["G3", "B3", "D4"], ["E3", "G#3", "B3"]]

/// Strati del brano, suonati insieme e sempre a tempo: ogni ambientazione ne alza o abbassa qualcuno.
enum Layer: Int, CaseIterable { case drums, shaker, bass, lead, arp, pad, bells }

/// Strati attivi per ambientazione (stesso ordine di `scenes`): a ogni cambio di scenario un dettaglio in più o in meno.
let sceneMusic: [Set<Layer>] = [
    [.drums, .bass, .lead],                      // giungla all'alba
    [.drums, .bass, .lead, .shaker],             // vulcani: + shaker
    [.drums, .bass, .lead, .shaker, .arp],       // canyon: + arpeggio
    [.drums, .bass, .lead, .shaker, .arp, .pad], // costa: + tappeto di accordi
    [.drums, .bass, .lead, .arp, .pad],          // vette innevate: − shaker, più calmo
    [.drums, .bass, .arp, .pad],                 // palude: − melodia, misteriosa
    [.drums, .bass, .arp, .pad, .bells],         // cimitero: + campanelle
    [.bass, .lead, .pad, .bells],                // notte: niente percussioni, torna la melodia
]

/// "A4" → 69 (numero MIDI)
func midi(_ n: Substring) -> Int {
    let names: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    return names[n.first!]! + (n.contains("#") ? 1 : 0) + 12 * (Int(String(n.last!))! + 1)
}

func freq(_ m: Int) -> Double { 440 * pow(2, Double(m - 69) / 12) }

/// Sintetizza tutti gli strati del brano (uno per `Layer`), stessa durata, pronti per il loop.
func renderStems() -> [[Float]] {
    let step = Int(songRate * 60 / bpm / 4), total = melody.count * 16 * step
    var stems = [[Float]](repeating: [Float](repeating: 0, count: total), count: Layer.allCases.count)
    var seed: UInt32 = 1
    func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed >> 8) / Double(1 << 23) - 1 }
    // le code delle note oltre la fine ricominciano dall'inizio: il loop non ha stacchi
    func add(_ layer: Layer, at start: Int, seconds: Double, _ f: (Double) -> Double) {
        for k in 0..<Int(seconds * songRate) { stems[layer.rawValue][(start + k) % total] += Float(f(Double(k) / songRate)) }
    }

    // melodia: onda quadra al 25% con un filo di vibrato
    let tokens = melody.flatMap { $0.split(separator: " ") }
    precondition(tokens.count == melody.count * 16, "ogni battuta deve avere 16 sedicesimi")
    for (i, tk) in tokens.enumerated() where tk != "." && tk != "-" {
        var len = 1
        while i + len < tokens.count && tokens[i + len] == "." { len += 1 }
        let f0 = freq(midi(tk)), dur = Double(len * step) / songRate
        var phase = 0.0
        add(.lead, at: i * step, seconds: dur + 0.03) { t in
            phase += f0 * (t > 0.15 ? 1 + 0.006 * sin(2 * .pi * 5.5 * t) : 1) / songRate
            let env = min(1, t / 0.005) * (0.55 + 0.45 * exp(-t / 0.08)) * (t > dur ? max(0, 1 - (t - dur) / 0.03) : 1)
            return (phase.truncatingRemainder(dividingBy: 1) < 0.25 ? 1 : -1) * env * 0.16
        }
    }
    let dry = stems[Layer.lead.rawValue]
    for i in 0..<total { stems[Layer.lead.rawValue][i] = dry[i] + 0.3 * dry[(i - 3 * step + total) % total] } // eco di 3 sedicesimi

    // basso: onda triangolare, note brevi sul ritmo sincopato
    for (b, root) in bassRoots.enumerated() {
        for (s, interval) in bassPattern.enumerated() {
            guard let interval else { continue }
            let f0 = freq(midi(Substring(root)) + interval), dur = Double(2 * step) / songRate
            var phase = 0.0
            add(.bass, at: (b * 16 + s) * step, seconds: dur) { t in
                phase += f0 / songRate
                let tri = 4 * abs(phase.truncatingRemainder(dividingBy: 1) - 0.5) - 1
                return tri * 0.28 * exp(-t / 0.12) * min(1, t / 0.003) * min(1, (dur - t) / 0.01)
            }
        }
    }

    // percussioni
    for b in melody.indices {
        for (s, c) in (b < 4 ? drumsA : drumsB).enumerated() {
            let at = (b * 16 + s) * step
            var phase = 0.0, last = 0.0
            switch c {
            case "K":
                add(.drums, at: at, seconds: 0.2) { t in
                    phase += (45 + 75 * exp(-t / 0.03)) / songRate
                    return sin(2 * .pi * phase) * 0.5 * exp(-t / 0.08)
                }
            case "T", "t":
                let base = c == "T" ? 150.0 : 230.0
                add(.drums, at: at, seconds: 0.25) { t in
                    phase += base * (0.6 + 0.4 * exp(-t / 0.05)) / songRate
                    return sin(2 * .pi * phase) * 0.32 * exp(-t / 0.09)
                }
            case "s":
                add(.shaker, at: at, seconds: 0.06) { t in
                    let n = noise(); defer { last = n }
                    return (n - last) * 0.07 * exp(-t / 0.015) // differenza tra campioni: rumore solo acuto
                }
            default: break
            }
        }
    }

    for (b, chord) in chords.enumerated() {
        let notes = chord.map { midi(Substring($0)) }
        // arpeggio: onda quadra stretta (12,5%), sedicesimi su e giù per l'accordo, un'ottava più su nella seconda metà
        for s in 0..<16 {
            let f0 = freq(notes[[0, 1, 2, 1][s % 4]] + 12 + (s >= 8 ? 12 : 0))
            var phase = 0.0
            add(.arp, at: (b * 16 + s) * step, seconds: 0.12) { t in
                phase += f0 / songRate
                return (phase.truncatingRemainder(dividingBy: 1) < 0.125 ? 1 : -1) * 0.06 * exp(-t / 0.05) * min(1, t / 0.002)
            }
        }
        // tappeto: l'accordo tenuto per tutta la battuta, due onde triangolari un filo stonate tra loro (effetto coro)
        let bar = Double(16 * step) / songRate
        for m in notes {
            for detune in [0.997, 1.003] {
                let f0 = freq(m) * detune
                var phase = 0.0
                add(.pad, at: b * 16 * step, seconds: bar) { t in
                    phase += f0 / songRate
                    let tri = 4 * abs(phase.truncatingRemainder(dividingBy: 1) - 0.5) - 1
                    return tri * 0.03 * min(1, t / 0.25) * min(1, (bar - t) / 0.15)
                }
            }
        }
        // campanelle: note acute dell'accordo in contrattempo, sinusoide con un armonico, lunga coda
        for (k, s) in [2, 7, 10, 15].enumerated() {
            let f0 = freq(notes[2 - k % 3] + 24)
            add(.bells, at: (b * 16 + s) * step, seconds: 0.6) { t in
                (sin(2 * .pi * f0 * t) + 0.3 * sin(4 * .pi * f0 * t)) * 0.06 * exp(-t / 0.25) * min(1, t / 0.002)
            }
        }
    }

    // stesso guadagno per tutti gli strati: anche con tutto acceso il mix non distorce
    let peak = (0..<total).map { i in abs(stems.reduce(0) { $0 + $1[i] }) }.max()!
    return stems.map { $0.map { $0 * 0.9 / peak } }
}

/// Effetto sonoro che si sente prendendo il power-up `p`, sintetizzato come la musica; picco 0,8.
func renderSFX(_ p: Power) -> [Float] {
    var seed: UInt32 = 7
    func noise() -> Double { seed = seed &* 1664525 &+ 1013904223; return Double(seed >> 8) / Double(1 << 23) - 1 }
    func make(_ seconds: Double, _ f: (Double) -> Double) -> [Float] { (0..<Int(seconds * songRate)).map { Float(f(Double($0) / songRate)) } }
    func env(_ t: Double, _ d: Double, attack: Double = 0.005, release: Double = 0.05) -> Double { min(1, t / attack) * min(1, max(0, (d - t) / release)) }
    func cycle(_ x: Double) -> Double { x - floor(x) }
    var a = 0.0, b = 0.0, c = 0.0, lo = 0.0 // fasi degli oscillatori e stato del filtro
    let out: [Float]
    switch p {
    case .shield: // scintillio metallico che sale di un'ottava, con tremolo
        out = make(0.55) { t in
            let f = 440 * pow(2, min(1, t / 0.18))
            a += f / songRate; b += f * 1.5 / songRate; c += f * 2.01 / songRate
            let ring = sin(2 * .pi * a) + 0.5 * sin(2 * .pi * b) + 0.3 * sin(2 * .pi * c)
            return ring * (0.7 + 0.3 * sin(2 * .pi * 18 * t)) * exp(-t * 4) * env(t, 0.55)
        }
    case .wings: // fruscio d'aria che si apre e si chiude + arpeggio magico che sale
        let notes = [1047.0, 1319, 1568, 2093]
        out = make(0.6) { t in
            lo += (noise() - lo) * (0.02 + 0.25 * sin(.pi * t / 0.6))
            let i = min(3, Int(t / 0.07)); a += notes[i] / songRate
            return (lo * 1.2 + sin(2 * .pi * a) * 0.45 * exp(-(t - Double(i) * 0.07) * 14)) * env(t, 0.6, release: 0.15)
        }
    case .slow: // nastro che rallenta (tono che crolla) e tic-tac della clessidra
        out = make(0.9) { t in
            a += 900 * pow(0.15, t / 0.9) / songRate
            let tick = t.truncatingRemainder(dividingBy: 0.22) < 0.012 ? noise() * 0.8 : 0
            return ((4 * abs(cycle(a) - 0.5) - 1) * 0.7 + tick) * env(t, 0.9, release: 0.25)
        }
    case .fire: // fiammata che si accende: rumore che si apre, rombo basso, scoppiettii
        out = make(0.8) { t in
            lo += (noise() - lo) * (0.05 + 0.4 * min(1, t / 0.12) * exp(-t * 2))
            a += 55 / songRate
            let crackle = noise() > 0.985 ? noise() * 1.5 : 0
            return (lo * 1.3 + 0.5 * sin(2 * .pi * a) * exp(-t * 3) + crackle) * env(t, 0.8, attack: 0.02, release: 0.3)
        }
    case .egg: // il guscio si crepa, poi due pigolii di pulcino
        out = make(0.7) { t in
            let crack = t < 0.05 ? noise() * (1 - t / 0.05) : 0
            var chirp = 0.0
            for start in [0.18, 0.38] where t >= start && t < start + 0.1 {
                let u = (t - start) / 0.1
                a += (2000 + 1400 * u) / songRate
                chirp = sin(2 * .pi * a) * sin(.pi * u)
            }
            return crack + chirp * 0.8
        }
    case .steak: // "nom nom", poi un'onda quadra che sale mentre il dino diventa gigante
        out = make(0.95) { t in
            var f = 0.0, amp = 0.0
            if t < 0.4 {
                let u = t.truncatingRemainder(dividingBy: 0.2) / 0.18
                if u < 1 { f = 150 - 50 * u; amp = sin(.pi * u) }
            } else if t > 0.42 {
                let u = (t - 0.42) / 0.5
                f = 150 * pow(4, u) * (1 + 0.03 * sin(2 * .pi * 12 * t)); amp = 0.7 * min(1, u * 8)
            }
            a += f / songRate
            return (cycle(a) < 0.5 ? 1 : -1) * amp * env(t, 0.95, release: 0.08)
        }
    case .roar:
        // ruggito: più fiato che nota. Gola = dente di sega grave che sale e poi crolla; fiato = rumore in banda media;
        // tutto "graffiato" da una modulazione veloce e irregolare; poca saturazione; il volume cresce e si spegne.
        let d = 1.4
        var hp = 0.0, band = 0.0, jitter = 0.0, smooth = 0.0
        out = make(d) { t in
            let u = t / d, contour = sin(.pi * min(1, u))
            let f0 = (65 + 60 * contour - 25 * max(0, u - 0.7)) * (1 + 0.04 * noise())
            a += f0 / songRate; b += f0 / 2 / songRate
            jitter += (noise() - jitter) * 0.002 // la ruvidità non è regolare: rallenta e accelera
            c += (30 + 12 * contour + 20 * jitter) / songRate
            let rough = 0.45 + 0.55 * abs(sin(2 * .pi * c))
            let n = noise()
            hp += (n - hp) * 0.03 // toglie i bassi dal rumore...
            band += ((n - hp) - band) * 0.1 // ...e gli acuti: resta la banda del fiato, circa 200–700 Hz
            let raw = (0.6 * (2 * cycle(a) - 1) + 0.4 * sin(2 * .pi * b) + 2.2 * band * (0.5 + contour)) * rough
            smooth += (tanh(raw * 1.4) - smooth) * (0.15 + 0.35 * contour) // il "filtro" si apre al culmine
            return smooth * pow(contour, 0.6) * env(t, d, attack: 0.12, release: 0.4)
        }
    case .amber: // campanelli di cristallo in arpeggio (parziali inarmoniche, come vetro)
        let notes = [1319.0, 1661, 1976, 2637]
        out = make(0.85) { t in
            var s = 0.0
            for (i, f) in notes.enumerated() where t >= Double(i) * 0.08 {
                let u = t - Double(i) * 0.08
                s += (sin(2 * .pi * f * u) + 0.4 * sin(2 * .pi * f * 2.76 * u) + 0.2 * sin(2 * .pi * f * 5.4 * u)) * exp(-u * 6)
            }
            return s * 0.3 * env(t, 0.85, release: 0.1)
        }
    }
    // stesso volume medio per tutti (a parità di picco le onde quadre suonerebbero molto più forti), picco al massimo 0,8
    let peak = out.map(abs).max()!, rms = sqrt(out.reduce(0) { $0 + $1 * $1 } / Float(out.count))
    let gain = min(0.8 / peak, 0.2 / rms)
    return out.map { $0 * gain }
}

func pcmBuffer(_ samples: [Float], _ format: AVAudioFormat) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = buf.frameCapacity
    samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
    return buf
}

@MainActor
final class Music {
    let engine = AVAudioEngine(), stemMixer = AVAudioMixerNode(), varispeed = AVAudioUnitVarispeed()
    var players: [AVAudioPlayerNode] = [] // uno per strato, indice = Layer.rawValue
    // M spegne tutto l'audio: musica ed effetti passano entrambi dal mixer principale
    var muted = false { didSet { engine.mainMixerNode.outputVolume = muted ? 0 : 0.5 } }
    // effetti: 4 voci a rotazione, così due power-up ravvicinati si sentono entrambi; fuori dal varispeed (niente Doppler)
    let voices = (0..<4).map { _ in AVAudioPlayerNode() }
    var nextVoice = 0
    var sfx: [Power: AVAudioPCMBuffer] = [:]

    init() {
        // strati → mixer → varispeed (velocità e intonazione insieme, come un nastro) → uscita
        let format = AVAudioFormat(standardFormatWithSampleRate: songRate, channels: 1)!
        engine.attach(stemMixer); engine.attach(varispeed)
        engine.connect(stemMixer, to: varispeed, format: nil)
        engine.connect(varispeed, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.5
        for (i, samples) in renderStems().enumerated() {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: stemMixer, format: format)
            player.scheduleBuffer(pcmBuffer(samples, format), at: nil, options: .loops)
            player.volume = sceneMusic[0].contains(Layer(rawValue: i)!) ? 1 : 0
            players.append(player)
        }
        for v in voices { engine.attach(v); engine.connect(v, to: engine.mainMixerNode, format: format) }
        for p in Power.allCases { sfx[p] = pcmBuffer(renderSFX(p), format) }
        engine.prepare()
    }

    /// Suona l'effetto del power-up appena preso.
    func play(_ p: Power) {
        guard engine.isRunning, let buf = sfx[p] else { return }
        let v = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        v.stop()
        v.scheduleBuffer(buf, at: nil)
        v.play()
    }

    func sync(playing: Bool) {
        if playing && !engine.isRunning {
            guard (try? engine.start()) != nil else { return } // senza uscita audio il gioco funziona lo stesso, muto
            if !players[0].isPlaying { // primo avvio: tutti gli strati partono nello stesso istante, così restano a tempo
                let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
                players.forEach { $0.play(at: start) }
            }
        } else if !playing && engine.isRunning {
            engine.pause() // mette in pausa tutti gli strati insieme
        }
    }

    /// A ogni frame: volumi degli strati verso quelli dell'ambientazione, intonazione verso quella del rallentatore.
    func update(dt: Double, scene: Int, slow: Bool) {
        let fade = Float(min(1, dt * 1.2)) // circa un secondo di dissolvenza
        for (i, player) in players.enumerated() {
            player.volume += ((sceneMusic[scene].contains(Layer(rawValue: i)!) ? 1 : 0) - player.volume) * fade
        }
        // effetto Doppler: col rallentatore la musica scivola più grave e lenta, poi risale quando finisce
        varispeed.rate += ((slow ? 0.72 : 1) - varispeed.rate) * Float(min(1, dt * 3))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let gameView = GameView(frame: NSRect(x: 0, y: 0, width: 600, height: 30))
    let music = Music()
    let preview = DinoPreview()
    var window: NSWindow!
    var menuView: NSView!, playView: NSView!
    var last = CACurrentMediaTime()

    var look = Look.load() {
        didSet { look.save(); preview.look = look; gameView.look = look; refreshShop() }
    }
    var wallet = Wallet.load() { didSet { if wallet != oldValue { wallet.save() } } }
    var banked = 0 // monete della partita in corso già versate nel wallet
    let stats = NSTextField(labelWithString: "") // record assoluto e monete, nel menù
    var shopWindow: NSWindow?
    let shopCoins = NSTextField(labelWithString: "")
    var shopCards: [(item: ShopItem, preview: DinoPreview, price: NSTextField, button: NSButton)] = []
    let speciesPop = NSPopUpButton(frame: .zero, pullsDown: false), hatPop = NSPopUpButton(frame: .zero, pullsDown: false)
    let glassesPop = NSPopUpButton(frame: .zero, pullsDown: false), neckPop = NSPopUpButton(frame: .zero, pullsDown: false)
    let skinWell = NSColorWell(style: .minimal), accentWell = NSColorWell(style: .minimal)

    func makeMenu() -> NSView {
        for (pop, titles) in [(speciesPop, Species.allCases.map(\.title)), (hatPop, Hat.allCases.map(\.title)),
                              (glassesPop, Glasses.allCases.map(\.title)), (neckPop, Neck.allCases.map(\.title))] {
            pop.addItems(withTitles: titles); pop.target = self; pop.action = #selector(lookChanged)
        }
        for well in [skinWell, accentWell] { well.target = self; well.action = #selector(lookChanged) }
        showLook()

        func label(_ s: String) -> NSTextField { NSTextField(labelWithString: s) }
        let grid = NSGridView(views: [
            [label("Specie"), speciesPop], [label("Colore"), skinWell], [label("Creste e dettagli"), accentWell],
            [label("Cappello"), hatPop], [label("Occhiali"), glassesPop], [label("Al collo"), neckPop],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        grid.yPlacement = .center // etichette centrate anche accanto ai selettori di colore
        grid.rowSpacing = 10
        let random = NSButton(title: "🎲  Combinazione casuale", target: self, action: #selector(randomLook))
        let controls = NSStackView(views: [grid, random])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 16

        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([preview.widthAnchor.constraint(equalToConstant: 320), preview.heightAnchor.constraint(equalToConstant: 240)])
        let row = NSStackView(views: [preview, controls])
        row.alignment = .centerY; row.spacing = 28

        let title = label("Jurassic Run"); title.font = .systemFont(ofSize: 28, weight: .heavy)
        let subtitle = label("Crea il tuo dinosauro, poi corri sulla Touch Bar.")
        subtitle.textColor = .secondaryLabelColor
        stats.font = .systemFont(ofSize: 15, weight: .semibold)
        let play = NSButton(title: "Gioca! 🦖", target: self, action: #selector(startGame))
        play.keyEquivalent = "\r" // Invio
        play.controlSize = .large
        let shop = NSButton(title: "🛒 Negozio", target: self, action: #selector(openShop))
        shop.controlSize = .large
        let buttons = NSStackView(views: [shop, play]); buttons.spacing = 12
        return stack([title, subtitle, stats, row, buttons])
    }

    // MARK: Negozio

    @objc func openShop() {
        if shopWindow == nil {
            func label(_ s: String, size: CGFloat, weight: NSFont.Weight) -> NSTextField {
                let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: size, weight: weight); return l
            }
            func card(_ item: ShopItem) -> NSView { // anteprima animata del tuo dino con l'oggetto, nome, prezzo, pulsante
                let preview = DinoPreview()
                preview.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([preview.widthAnchor.constraint(equalToConstant: 160), preview.heightAnchor.constraint(equalToConstant: 128)])
                let price = label("", size: 12, weight: .medium); price.textColor = .secondaryLabelColor
                let button = NSButton(title: "", target: self, action: #selector(shopAction))
                button.tag = ShopItem.all.firstIndex(of: item)!
                shopCards.append((item, preview, price, button))
                let v = NSStackView(views: [preview, label(item.title, size: 13, weight: .bold), price, button])
                v.orientation = .vertical; v.spacing = 6
                return v
            }
            func row(_ items: [ShopItem]) -> NSView { let r = NSStackView(views: items.map(card)); r.spacing = 14; r.alignment = .top; return r }
            shopCoins.font = .systemFont(ofSize: 16, weight: .semibold)
            let hint = label("Le monete si raccolgono correndo: gli archi sopra i cactus si prendono saltando.", size: 12, weight: .regular)
            hint.textColor = .secondaryLabelColor
            let content = stack([label("Negozio", size: 26, weight: .heavy), shopCoins,
                                 label("Skin", size: 16, weight: .bold), row(Costume.allCases.map { .costume($0) }),
                                 label("Accessori speciali", size: 16, weight: .bold), row(Gadget.allCases.map { .gadget($0) }), hint])
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Negozio · Jurassic Run"
            w.isReleasedWhenClosed = false
            w.contentView = content
            w.setContentSize(content.fittingSize)
            w.touchBar = window.touchBar // anche col negozio davanti, la Touch Bar resta quella del gioco
            w.center()
            shopWindow = w
        }
        refreshShop()
        shopWindow!.makeKeyAndOrderFront(nil)
    }

    /// Aggiorna monete, record e pulsanti di negozio e menù.
    func refreshShop() {
        stats.stringValue = "🏆 Record assoluto: \(wallet.best)      🪙 \(wallet.coins) monete"
        shopCoins.stringValue = "🪙 \(wallet.coins) monete"
        for c in shopCards {
            let owned = wallet.owned.contains(c.item.id), worn = c.item.isWorn(in: look)
            c.price.stringValue = owned ? "✓ È tuo" : "🪙 \(c.item.price)"
            c.button.title = !owned ? "Compra" : worn ? "Togli" : "Indossa"
            c.button.isEnabled = owned || wallet.coins >= c.item.price
            c.preview.look = c.item.wearing(true, in: look)
        }
    }

    @objc func shopAction(_ sender: NSButton) {
        let item = ShopItem.all[sender.tag]
        if wallet.owned.contains(item.id) {
            look = item.wearing(!item.isWorn(in: look), in: look) // indossa o togli
        } else if wallet.buy(item) {
            look = item.wearing(true, in: look) // appena comprato: lo indossi subito
        }
        refreshShop()
    }

    func makePlayView() -> NSView {
        let info = NSTextField(wrappingLabelWithString: """
            Il dinosauro corre sulla Touch Bar! Tieni questa finestra in primo piano.
            Salta i cactus: tocca la Touch Bar, freccia su ↑ o Spazio.
            Esc: pausa · M: audio on/off
            Power-up: 🛡️ scudo (assorbe un cactus) · 🪽 ali (doppio salto) · ⏳ rallenta il tempo
            🌺 fiore di fuoco: palle di fuoco che spaccano i cactus (→, F o tocca la metà destra della barra)
            🥚 uovo: vita extra · 🍖 bistecca: diventi gigante e schiacci i cactus · 🦖 ruggito: spazza via i cactus · 💎 ambra: punti doppi
            """)
        info.preferredMaxLayoutWidth = 440
        return stack([info, NSButton(title: "← Torna al menù", target: self, action: #selector(showMenu))])
    }

    func stack(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical; s.alignment = .centerX; s.spacing = 14
        s.translatesAutoresizingMaskIntoConstraints = false
        // margini con vincoli espliciti: con l'allineamento al centro gli edgeInsets non allargano la finestra
        let box = NSView()
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 28), s.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -28),
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 22), s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -22),
        ])
        return box
    }

    func show(_ v: NSView) {
        window.contentView = v
        window.setContentSize(v.fittingSize)
    }

    /// Porta i controlli e le anteprime in linea con `look`.
    func showLook() {
        speciesPop.selectItem(at: look.species.rawValue); hatPop.selectItem(at: look.hat.rawValue)
        glassesPop.selectItem(at: look.glasses.rawValue); neckPop.selectItem(at: look.neck.rawValue)
        skinWell.color = look.skinColor; accentWell.color = look.accentColor
        preview.look = look; gameView.look = look
    }

    @objc func lookChanged() {
        func rgbOf(_ c: NSColor) -> [CGFloat] { let s = c.usingColorSpace(.sRGB)!; return [s.redComponent, s.greenComponent, s.blueComponent] }
        look = Look(species: Species(rawValue: speciesPop.indexOfSelectedItem)!, hat: Hat(rawValue: hatPop.indexOfSelectedItem)!,
                    glasses: Glasses(rawValue: glassesPop.indexOfSelectedItem)!, neck: Neck(rawValue: neckPop.indexOfSelectedItem)!,
                    skin: rgbOf(skinWell.color), accent: rgbOf(accentWell.color),
                    costume: look.costume, gadget: look.gadget) // skin e accessorio del negozio restano
    }

    @objc func randomLook() {
        func color() -> NSColor { NSColor(hue: .random(in: 0...1), saturation: .random(in: 0.45...0.8), brightness: .random(in: 0.7...0.95), alpha: 1) }
        skinWell.color = color(); accentWell.color = color()
        for pop in [speciesPop, hatPop, glassesPop, neckPop] { pop.selectItem(at: .random(in: 0..<pop.numberOfItems)) }
        lookChanged()
    }

    @objc func startGame() {
        gameView.game = Game()
        gameView.inMenu = false
        show(playView)
    }

    @objc func showMenu() {
        gameView.inMenu = true // la partita in corso finisce
        gameView.game = Game()
        refreshShop() // record e monete aggiornati
        show(menuView)
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Jurassic Run"
        menuView = makeMenu()
        playView = makePlayView()
        refreshShop()
        show(menuView)

        let bar = NSTouchBar()
        bar.defaultItemIdentifiers = [.init("game")]
        let item = NSCustomTouchBarItem(identifier: .init("game"))
        item.view = gameView
        // largo quanto possibile, ma comprimibile così il sistema non nasconde l'elemento
        let wide = gameView.widthAnchor.constraint(equalToConstant: 1000)
        wide.priority = .defaultLow
        NSLayoutConstraint.activate([wide, gameView.widthAnchor.constraint(greaterThanOrEqualToConstant: 400)])
        bar.templateItems = [item]
        window.touchBar = bar

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [gameView, music] e in
            switch e.keyCode {
            case 126, 49: if !e.isARepeat { gameView.tap() }; return nil // freccia su, Spazio (tenerli premuti non conta)
            case 53: gameView.togglePause(); return nil // Esc (anche quello della Touch Bar)
            case 124, 3: if !gameView.inMenu { gameView.game.shoot() }; return nil // freccia destra o F: spara (tenendo premuto, raffica)
            case 46: music.muted.toggle(); return nil // M
            default: return e
            }
        }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTime()
                let dt = min(CGFloat(now - self.last), 0.05)
                self.gameView.tick(dt)
                self.last = now
                if self.gameView.inMenu { self.preview.time += dt }
                if self.shopWindow?.isVisible == true { self.shopCards.forEach { $0.preview.time += dt } }
                // versa subito nel wallet le monete prese e aggiorna il record assoluto: niente si perde se l'app si chiude
                let g = self.gameView.game
                if g.coinsTaken < self.banked { self.banked = 0 } // è iniziata una partita nuova
                self.wallet.coins += g.coinsTaken - self.banked
                self.banked = g.coinsTaken
                self.wallet.best = max(self.wallet.best, g.score)
                // la musica suona nel menù e in partita, si ferma in pausa o se l'app non è in primo piano
                self.music.sync(playing: NSApp.isActive && (self.gameView.inMenu || !self.gameView.game.paused))
                self.gameView.game.picked.forEach(self.music.play) // effetto sonoro di ogni power-up preso
                self.gameView.game.picked.removeAll()
                let game = self.gameView.game
                self.music.update(dt: Double(dt), scene: Int(game.distance / sceneLength) % scenes.count, slow: game.active[.slow] != nil)
            }
        }
    }

    // passando a un'altra app la Touch Bar non mostra più il gioco: meglio non morire alla cieca
    func applicationDidResignActive(_ note: Notification) {
        if !gameView.game.over && !gameView.inMenu { gameView.game.paused = true }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

if CommandLine.arguments.contains("--selftest") {
    var g = Game()
    g.jump(); g.step(0.05, width: 0)
    assert(g.playerY > 0, "il salto deve sollevare il dino")
    for _ in 0..<40 { g.step(0.05, width: 0) }
    assert(g.playerY == 0 && g.vy == 0, "il dino deve atterrare")
    assert(groundY + maxY + 12 <= 30.5, "il dino non deve uscire dalla Touch Bar")

    // ogni tipo di cactus, alla misura massima, dev'essere saltabile con il tempismo giusto
    for k in cactusKinds {
        let clearable = (0..<60).contains { jumpFrame in
            var s = Game()
            s.nextSpawn = .infinity
            s.obstacles = [CGRect(x: 150, y: groundY, width: k.w.upperBound, height: k.h.upperBound)]
            for f in 0..<120 { if f == jumpFrame { s.jump() }; s.step(1.0 / 60, width: 0) }
            return !s.over
        }
        assert(clearable, "cactus \(k) impossibile da saltare")
    }

    var h = Game()
    h.obstacles = [CGRect(x: 42, y: groundY, width: 8, height: 10)]
    h.step(0.01, width: 0)
    assert(h.over, "toccare un cactus fa perdere")

    var sh = Game()
    sh.items = [(CGRect(x: 42, y: groundY + 2, width: 8, height: 8), .shield)]
    sh.step(0.01, width: 0)
    assert(sh.active[.shield] != nil && sh.items.isEmpty, "toccare un power-up lo attiva")
    sh.obstacles = [CGRect(x: 42, y: groundY, width: 8, height: 10)]
    sh.step(0.01, width: 0)
    assert(!sh.over && sh.obstacles.isEmpty && sh.active[.shield] == nil, "lo scudo assorbe un cactus e si consuma")

    var fz = Game()
    fz.nextSpawn = .infinity
    fz.shoot()
    assert(fz.fireballs.isEmpty, "senza fiore di fuoco non si spara")
    fz.active[.fire] = 10
    fz.obstacles = [CGRect(x: 160, y: groundY, width: 6.5, height: 13)] // il cactus più alto
    fz.shoot(); fz.shoot()
    assert(fz.fireballs.count == 1, "tra un colpo e l'altro c'è una pausa")
    for _ in 0..<60 where !fz.obstacles.isEmpty { fz.step(1.0 / 60, width: 680) }
    assert(fz.obstacles.isEmpty && !fz.over && !fz.bursts.isEmpty && fz.fireballs.isEmpty, "la palla di fuoco spacca il cactus e si consuma")
    var bz = Game()
    bz.nextSpawn = .infinity; bz.active[.fire] = 10; bz.shoot()
    for _ in 0..<120 {
        bz.step(1.0 / 60, width: 5000)
        assert(bz.fireballs.allSatisfy { $0.y >= groundY + fireballRadius - 0.01 && $0.y < 14 }, "la palla rimbalza restando bassa")
    }
    assert(bz.fireballs.count == 1, "senza bersagli la palla continua a rimbalzare")

    let hit = CGRect(x: 42, y: groundY, width: 8, height: 10) // cactus addosso al dino
    var ez = Game()
    ez.nextSpawn = .infinity; ez.active[.egg] = Power.egg.duration
    for _ in 0..<600 { ez.step(1.0 / 60, width: 0) } // 10 s
    assert(ez.active[.egg] != nil, "l'uovo resta finché non serve")
    ez.obstacles = [hit]; ez.step(0.01, width: 0)
    assert(!ez.over && ez.active[.egg] == nil && ez.obstacles.isEmpty && ez.notice != nil, "l'uovo salva una volta")
    ez.obstacles = [hit]; ez.step(0.01, width: 0)
    assert(ez.over, "senza uovo si perde")

    var gz = Game()
    gz.nextSpawn = .infinity; gz.active[.steak] = Power.steak.duration
    for _ in 0..<30 { gz.step(1.0 / 60, width: 0) }
    assert(abs(gz.playerRect.height - 18) < 0.01, "con la bistecca il dino diventa 1,5 volte più grande")
    gz.obstacles = [hit]; gz.step(0.01, width: 0)
    assert(!gz.over && gz.obstacles.isEmpty && gz.active[.steak] != nil, "da gigante schiaccia i cactus senza consumare la bistecca")
    gz.jump()
    for _ in 0..<60 { gz.step(1.0 / 60, width: 0); assert(gz.playerRect.maxY <= 30.01, "da gigante resta dentro la Touch Bar") }

    var rz = Game()
    rz.nextSpawn = .infinity
    rz.obstacles = [CGRect(x: 200, y: groundY, width: 6, height: 9), CGRect(x: 400, y: groundY, width: 6, height: 12)]
    rz.items = [(CGRect(x: 42, y: groundY + 2, width: 8, height: 8), .roar)]
    rz.step(0.01, width: 0)
    assert(rz.obstacles.isEmpty && rz.bursts.count == 2 && rz.notice != nil, "il ruggito spazza via tutti i cactus")

    var az = Game(), nz = Game()
    az.nextSpawn = .infinity; nz.nextSpawn = .infinity; az.active[.amber] = Power.amber.duration
    for _ in 0..<120 { az.step(1.0 / 60, width: 0); nz.step(1.0 / 60, width: 0) }
    assert(nz.score > 0 && abs(az.points - 2 * nz.points) < 0.01, "l'ambra raddoppia i punti")

    let oldSave = #"{"species":2,"hat":1,"glasses":0,"neck":0,"skin":[0.1,0.2,0.3],"accent":[1,1,1]}"#
    let old = try! JSONDecoder().decode(Look.self, from: Data(oldSave.utf8))
    assert(old.species == .stego && old.costume == nil && old.gadget == nil, "i salvataggi di prima del negozio si leggono ancora")
    var dressed = Look(); dressed.costume = .galaxy; dressed.gadget = .laser
    assert(try! JSONDecoder().decode(Look.self, from: JSONEncoder().encode(dressed)) == dressed, "skin e accessorio si salvano")

    assert(Set(ShopItem.all.map(\.id)).count == 10 && ShopItem.all.allSatisfy { $0.price > 0 }, "10 oggetti con id unici e prezzo")
    var purse = Wallet(coins: 100)
    assert(!purse.buy(.costume(.galaxy)) && purse.coins == 100, "senza monete sufficienti non si compra")
    assert(purse.buy(.gadget(.headphones)) && purse.coins == 40 && purse.owned.contains("extra.headphones"), "comprare scala le monete")
    assert(!purse.buy(.gadget(.headphones)) && purse.coins == 40, "non si paga due volte")

    var cz = Game()
    cz.nextSpawn = .infinity
    cz.coins = [CGPoint(x: 47, y: groundY + 5), CGPoint(x: 300, y: groundY + 5)]
    cz.step(0.01, width: 0)
    assert(cz.coinsTaken == 1 && cz.coins.count == 1 && cz.sparkles.count == 1, "si prende la moneta toccata")
    let arcOK = (0..<60).contains { jumpFrame in // l'arco sopra il cactus più alto si raccoglie saltandolo
        var s = Game()
        s.nextSpawn = .infinity
        let cactus = CGRect(x: 150, y: groundY, width: 7, height: 13)
        s.obstacles = [cactus]; s.coins = Game.coinArc(over: cactus.midX)
        for f in 0..<120 { if f == jumpFrame { s.jump() }; s.step(1.0 / 60, width: 0) }
        return !s.over && s.coinsTaken >= 4
    }
    assert(arcOK, "l'arco di monete si prende saltando il cactus")

    let effects = Power.allCases.map(renderSFX)
    assert(effects.allSatisfy { $0.count > 4000 && $0.allSatisfy { $0.isFinite && abs($0) <= 0.801 } }, "effetti validi e senza distorsione")
    assert(Set(effects.map { $0.prefix(4000).map { Int($0 * 1000) } }).count == Power.allCases.count, "un effetto diverso per ogni power-up")
    let roar = renderSFX(.roar)
    func energy(_ from: Double, _ to: Double) -> Float { roar[Int(from * Double(roar.count))..<Int(to * Double(roar.count))].reduce(0) { $0 + $1 * $1 } }
    assert(roar.count == effects.map(\.count).max() && energy(0.4, 0.6) > 4 * energy(0, 0.2) && energy(0.4, 0.6) > 4 * energy(0.8, 1),
           "il ruggito è il più lungo e cresce fino a metà, poi si spegne")
    var sz = Game()
    sz.nextSpawn = .infinity
    sz.items = [(CGRect(x: 42, y: groundY + 2, width: 8, height: 8), .egg)]
    sz.step(0.01, width: 0)
    assert(sz.picked == [.egg], "prendere un power-up fa partire il suo effetto")

    var wj = Game()
    wj.jump(); for _ in 0..<10 { wj.step(1.0 / 60, width: 0) }
    let vyBefore = wj.vy
    wj.jump()
    assert(wj.vy == vyBefore, "senza ali niente doppio salto")
    wj.active[.wings] = 5
    wj.jump()
    assert(wj.vy > vyBefore, "con le ali si salta anche in aria")
    for _ in 0..<60 { wj.step(1.0 / 60, width: 0); assert(wj.playerY <= maxY, "il doppio salto resta nella Touch Bar") }

    var pz = Game()
    pz.paused = true
    pz.jump(); pz.step(0.1, width: 0)
    assert(pz.distance == 0 && pz.playerY == 0, "in pausa il gioco è fermo")

    assert(midi("A4") == 69 && midi("C5") == 72 && midi("G#5") == 80 && midi("D2") == 38, "lettura delle note")
    let stems = renderStems()
    let length = melody.count * 16 * Int(songRate * 60 / bpm / 4)
    assert(stems.count == Layer.allCases.count && stems.allSatisfy { $0.count == length }, "strati tutti della stessa durata")
    assert(stems.allSatisfy { $0.contains { $0 != 0 } }, "ogni strato suona qualcosa")
    let full = (0..<length).map { i in stems.reduce(0) { $0 + $1[i] } }
    assert(full.allSatisfy { $0.isFinite && abs($0) <= 0.91 }, "anche con tutti gli strati il mix non distorce")
    assert(sceneMusic.count == scenes.count, "ogni ambientazione ha la sua musica")
    assert(zip(sceneMusic, sceneMusic.dropFirst() + [sceneMusic[0]]).allSatisfy { $0 != $1 }, "la musica cambia a ogni cambio di scenario")

    let custom = Look(species: .stego, hat: .crown, glasses: .heart, neck: .bowTie, skin: [0.1, 0.2, 0.3], accent: [0.9, 0.8, 0.7])
    assert(try! JSONDecoder().decode(Look.self, from: JSONEncoder().encode(custom)) == custom, "la personalizzazione si salva")
    for sp in Species.allCases {
        let a = sp.fit
        assert([a.hat, a.eye, a.neck].allSatisfy { NSRect(x: 0, y: 0, width: 14.01, height: 12.01).contains($0) }, "\(sp): accessori fuori dal corpo")
    }

    print("selftest ok")
    exit(0)
}

MainActor.assumeIsolated {
    if let i = CommandLine.arguments.firstIndex(of: "--icon") { renderIcon(to: CommandLine.arguments[i + 1]); exit(0) }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
