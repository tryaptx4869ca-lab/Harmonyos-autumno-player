/**
 * DEFLATE（RFC 1951）解压。
 *
 * ## 为什么要有这个文件
 *
 * 哔哩哔哩的弹幕接口 `x/v1/dm/list.so?oid={cid}` 返回的是**压缩过的 XML**：
 * 响应头写着 `Content-Encoding: deflate`，实测（2026-09-19）响应体是
 * **裸 DEFLATE**（首字节 `0x94`，既不是 gzip 的 `1F 8B`，也不是 zlib 的
 * `78` 开头），服务端**无视 `Accept-Encoding: identity`** 一律压缩。
 *
 * 本工程其它请求都走 `@ohos.net.http` 的 `expectDataType: STRING`
 * （见 `ApiClient.bodyOf`），压缩字节被当 UTF-8 解码就是一堆乱码，
 * 拿不到任何弹幕。系统 `@ohos.zlib` 只提供**按文件**的 `decompressFile`，
 * 且走的是 zlib/gzip 的头判定，对裸 DEFLATE 不保证可用；
 * 为了不把「能不能解压」押在系统实现的内部细节上，这里自己解。
 *
 * ## 覆盖范围
 *
 * 只实现解压（不需要压缩）：
 *   - 存块（BTYPE 0）、固定霍夫曼（BTYPE 1）、动态霍夫曼（BTYPE 2）；
 *   - `InflateRaw.auto()` 按魔数自动识别裸 DEFLATE / zlib / gzip，
 *     这样无论 `@ohos.net.http` 有没有替我们解压过，两条路都能落地。
 *
 * 算法按 puff.c（zlib 官方的教学实现）的结构写：
 * 逐位读、按「码长 → 符号表」建规范霍夫曼表、`decode()` 逐位比较。
 * 弹幕 XML 一次最大几百 KB，够用且没有额外依赖。
 */

/** 解压输出：按需翻倍增长（一次预分配会浪费，弹幕量级 40–300KB）。 */
class ByteSink {
  private buffer: Uint8Array;
  private length: number = 0;

  constructor(capacity: number) {
    this.buffer = new Uint8Array(capacity > 16 ? capacity : 16);
  }

  size(): number {
    return this.length;
  }

  push(value: number): void {
    this.ensure(1);
    this.buffer[this.length] = value & 0xFF;
    this.length += 1;
  }

  /**
   * LZ77 回溯拷贝。
   *
   * `distance` 允许小于 `count`（重叠拷贝，例如「aaaa…」），所以必须
   * **逐字节**拷、边拷边扩——一次性 `set` 会在重叠时拷错。
   */
  copyBack(distance: number, count: number): void {
    if (distance <= 0 || distance > this.length) {
      throw new Error(`DEFLATE 回溯距离越界（${distance}）`);
    }
    this.ensure(count);
    let from: number = this.length - distance;
    for (let i = 0; i < count; i++) {
      this.buffer[this.length] = this.buffer[from];
      this.length += 1;
      from += 1;
    }
  }

  toArray(): Uint8Array {
    return this.buffer.slice(0, this.length);
  }

  private ensure(extra: number): void {
    if (this.length + extra <= this.buffer.length) {
      return;
    }
    let capacity: number = this.buffer.length * 2;
    while (capacity < this.length + extra) {
      capacity *= 2;
    }
    const grown: Uint8Array = new Uint8Array(capacity);
    grown.set(this.buffer);
    this.buffer = grown;
  }
}

/**
 * 逐位读取器。
 *
 * DEFLATE 有两套位序，**必须分清楚**：
 *   - 霍夫曼码：从最高位开始（`Huffman.decode` 逐位左移拼码）；
 *   - 额外位 / 整数：从最低位开始（`bits(n)` 就是 LSB-first）。
 */
class BitReader {
  private readonly data: Uint8Array;
  private position: number;
  private bitBuffer: number = 0;
  private bitCount: number = 0;

  constructor(data: Uint8Array, offset: number) {
    this.data = data;
    this.position = offset;
  }

  /** 读 `count` 位（低位在前）；越界按 0 补，让上层用校验兜底。 */
  bits(count: number): number {
    let value: number = this.bitBuffer;
    while (this.bitCount < count) {
      const byte: number =
        this.position < this.data.length ? this.data[this.position] : 0;
      this.position += 1;
      value |= byte << this.bitCount;
      this.bitCount += 8;
    }
    this.bitBuffer = value >>> count;
    this.bitCount -= count;
    return value & ((1 << count) - 1);
  }

  /**
   * 丢开位缓冲、对齐到字节边界（存块用）。
   *
   * `position` 一直指向「还没进过位缓冲的第一个字节」，所以丢弃缓冲即可。
   */
  alignToByte(): void {
    this.bitBuffer = 0;
    this.bitCount = 0;
  }
}

/** 规范霍夫曼表（码长 → 符号）。 */
class Huffman {
  private readonly counts: Int32Array = new Int32Array(16);
  private symbols: Int32Array = new Int32Array(0);

  constructor(lengths: Int32Array, count: number) {
    const offsets: Int32Array = new Int32Array(16);
    for (let i = 0; i < count; i++) {
      const length: number = i < lengths.length ? lengths[i] : 0;
      if (length > 0 && length < 16) {
        this.counts[length] += 1;
      }
    }
    // 码长 0 = 该符号不参与编码，建表时要排除
    this.counts[0] = 0;
    let total: number = 0;
    for (let len = 1; len < 16; len++) {
      offsets[len] = total;
      total += this.counts[len];
    }
    this.symbols = new Int32Array(total);
    for (let symbol = 0; symbol < count; symbol++) {
      const length: number = symbol < lengths.length ? lengths[symbol] : 0;
      if (length > 0 && length < 16) {
        this.symbols[offsets[length]] = symbol;
        offsets[length] += 1;
      }
    }
  }

  /** 解出一个符号；码不合法时抛异常。 */
  decode(reader: BitReader): number {
    let code: number = 0;
    let first: number = 0;
    let index: number = 0;
    for (let len = 1; len < 16; len++) {
      code |= reader.bits(1);
      const count: number = this.counts[len];
      if (code - first < count) {
        return this.symbols[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }
    throw new Error('DEFLATE 霍夫曼码无效');
  }
}

/** 动态霍夫曼块读出来的两张表（长度表 + 距离表）。 */
class DynamicTables {
  literal: Int32Array = new Int32Array(0);
  literalCount: number = 0;
  distance: Int32Array = new Int32Array(0);
  distanceCount: number = 0;
}

export class InflateRaw {
  /** 长度码 257–285 的基准长度。 */
  private static readonly LENGTH_BASE: number[] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51,
    59, 67, 83, 99, 115, 131, 163, 195, 227, 258
  ];
  /** 长度码 257–285 的额外位数。 */
  private static readonly LENGTH_EXTRA: number[] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
    4, 4, 4, 4, 5, 5, 5, 5, 0
  ];
  /** 距离码 0–29 的基准距离。 */
  private static readonly DISTANCE_BASE: number[] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
    513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
  ];
  /** 距离码 0–29 的额外位数。 */
  private static readonly DISTANCE_EXTRA: number[] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
    9, 9, 10, 10, 11, 11, 12, 12, 13, 13
  ];
  /** 动态块里「码长表」自己的码长排列顺序（RFC 1951 §3.2.7）。 */
  private static readonly CODE_LENGTH_ORDER: number[] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
  ];

  private static fixedLiteralTable: Huffman | null = null;
  private static fixedDistanceTable: Huffman | null = null;

  /** 解压一段裸 DEFLATE 流（`offset` 之前是外壳，例如 gzip 的 10 字节头）。 */
  static raw(data: Uint8Array, offset: number): Uint8Array {
    if (data.length === 0) {
      return new Uint8Array(0);
    }
    const reader: BitReader = new BitReader(data, offset);
    const out: ByteSink = new ByteSink(data.length * 4);
    let last: number = 0;
    while (last === 0) {
      last = reader.bits(1);
      const type: number = reader.bits(2);
      if (type === 0) {
        InflateRaw.readStoredBlock(reader, out);
      } else if (type === 1) {
        InflateRaw.readCompressedBlock(reader, out,
          InflateRaw.fixedLiteral(), InflateRaw.fixedDistance());
      } else if (type === 2) {
        const tables: DynamicTables = InflateRaw.readDynamicTables(reader);
        const literal: Huffman =
          new Huffman(tables.literal, tables.literalCount);
        const distance: Huffman =
          new Huffman(tables.distance, tables.distanceCount);
        InflateRaw.readCompressedBlock(reader, out, literal, distance);
      } else {
        throw new Error('DEFLATE 块类型 3 非法');
      }
    }
    return out.toArray();
  }

  /** gzip（RFC 1952）：10 字节头之后就是 DEFLATE 流。 */
  static gzip(data: Uint8Array): Uint8Array {
    return InflateRaw.raw(data, 10);
  }

  /** zlib（RFC 1950）：2 字节头之后就是 DEFLATE 流。 */
  static zlib(data: Uint8Array): Uint8Array {
    return InflateRaw.raw(data, 2);
  }

  /**
   * 按魔数自动识别外壳。
   *
   * 哔哩哔哩实测发的是**裸 DEFLATE**；这里把 gzip / zlib 一起认了，
   * 是为了「万一哪天它换了外壳」也不用改调用方。
   */
  static auto(data: Uint8Array): Uint8Array {
    if (data.length >= 2 && data[0] === 0x1F && data[1] === 0x8B) {
      return InflateRaw.gzip(data);
    }
    if (data.length >= 2 && (data[0] & 0x0F) === 0x08 &&
      ((data[0] << 8) | data[1]) % 31 === 0) {
      return InflateRaw.zlib(data);
    }
    return InflateRaw.raw(data, 0);
  }

  /** 存块：对齐后读 LEN / NLEN 与原始字节。 */
  private static readStoredBlock(reader: BitReader, out: ByteSink): void {
    reader.alignToByte();
    const length: number = reader.bits(16);
    const inverse: number = reader.bits(16);
    if ((length ^ 0xFFFF) !== inverse) {
      throw new Error('DEFLATE 存块长度校验失败');
    }
    for (let i = 0; i < length; i++) {
      out.push(reader.bits(8));
    }
  }

  /** 压缩块：逐符号解，256 = 块结束。 */
  private static readCompressedBlock(reader: BitReader, out: ByteSink,
    literal: Huffman, distance: Huffman): void {
    for (;;) {
      const symbol: number = literal.decode(reader);
      if (symbol === 256) {
        return;
      }
      if (symbol < 256) {
        out.push(symbol);
        continue;
      }
      const index: number = symbol - 257;
      if (index >= InflateRaw.LENGTH_BASE.length) {
        throw new Error(`DEFLATE 长度码无效（${symbol}）`);
      }
      const length: number = InflateRaw.LENGTH_BASE[index] +
        reader.bits(InflateRaw.LENGTH_EXTRA[index]);
      const distSymbol: number = distance.decode(reader);
      if (distSymbol < 0 ||
        distSymbol >= InflateRaw.DISTANCE_BASE.length) {
        throw new Error(`DEFLATE 距离码无效（${distSymbol}）`);
      }
      const dist: number = InflateRaw.DISTANCE_BASE[distSymbol] +
        reader.bits(InflateRaw.DISTANCE_EXTRA[distSymbol]);
      out.copyBack(dist, length);
    }
  }

  /** 动态块的两张表。 */
  private static readDynamicTables(reader: BitReader): DynamicTables {
    const literalCount: number = reader.bits(5) + 257;
    const distanceCount: number = reader.bits(5) + 1;
    const codeLengthCount: number = reader.bits(4) + 4;

    const codeLengths: Int32Array = new Int32Array(19);
    for (let i = 0; i < codeLengthCount; i++) {
      codeLengths[InflateRaw.CODE_LENGTH_ORDER[i]] = reader.bits(3);
    }
    const codeTable: Huffman = new Huffman(codeLengths, 19);

    const total: number = literalCount + distanceCount;
    const lengths: Int32Array = new Int32Array(total);
    let index: number = 0;
    while (index < total) {
      const symbol: number = codeTable.decode(reader);
      if (symbol < 16) {
        lengths[index] = symbol;
        index += 1;
        continue;
      }
      let value: number = 0;
      let repeat: number = 0;
      if (symbol === 16) {
        if (index === 0) {
          throw new Error('DEFLATE 重复码没有前置长度');
        }
        value = lengths[index - 1];
        repeat = 3 + reader.bits(2);
      } else if (symbol === 17) {
        value = 0;
        repeat = 3 + reader.bits(3);
      } else if (symbol === 18) {
        value = 0;
        repeat = 11 + reader.bits(7);
      } else {
        throw new Error(`DEFLATE 码长符号无效（${symbol}）`);
      }
      while (repeat > 0 && index < total) {
        lengths[index] = value;
        index += 1;
        repeat -= 1;
      }
    }

    const tables = new DynamicTables();
    tables.literalCount = literalCount;
    tables.distanceCount = distanceCount;
    tables.literal = lengths.slice(0, literalCount);
    tables.distance = lengths.slice(literalCount, total);
    return tables;
  }

  /** 固定霍夫曼块的字面/长度表（RFC 1951 §3.2.6）。 */
  private static fixedLiteral(): Huffman {
    if (InflateRaw.fixedLiteralTable === null) {
      const lengths: Int32Array = new Int32Array(288);
      for (let i = 0; i < 144; i++) {
        lengths[i] = 8;
      }
      for (let i = 144; i < 256; i++) {
        lengths[i] = 9;
      }
      for (let i = 256; i < 280; i++) {
        lengths[i] = 7;
      }
      for (let i = 280; i < 288; i++) {
        lengths[i] = 8;
      }
      InflateRaw.fixedLiteralTable = new Huffman(lengths, 288);
    }
    return InflateRaw.fixedLiteralTable;
  }

  /** 固定霍夫曼块的距离表（30 个 5 位码 + 2 个未用）。 */
  private static fixedDistance(): Huffman {
    if (InflateRaw.fixedDistanceTable === null) {
      const lengths: Int32Array = new Int32Array(30);
      for (let i = 0; i < lengths.length; i++) {
        lengths[i] = 5;
      }
      InflateRaw.fixedDistanceTable = new Huffman(lengths, 30);
    }
    return InflateRaw.fixedDistanceTable;
  }
}
