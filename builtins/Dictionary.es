/* -*- mode: java -*-
 *
 * ECMAScript 4 samples - a "Dictionary" object
 *
 * The following licensing terms and conditions apply and must be
 * accepted in order to use the Reference Implementation:
 *
 *    1. This Reference Implementation is made available to all
 * interested persons on the same terms as Ecma makes available its
 * standards and technical reports, as set forth at
 * http://www.ecma-international.org/publications/.
 *
 *    2. All liability and responsibility for any use of this Reference
 * Implementation rests with the user, and not with any of the parties
 * who contribute to, or who own or hold any copyright in, this Reference
 * Implementation.
 *
 *    3. THIS REFERENCE IMPLEMENTATION IS PROVIDED BY THE COPYRIGHT
 * HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 * OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
 * IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 *
 * End of Terms and Conditions
 *
 * Copyright (c) 2007 Adobe Systems Inc., The Mozilla Foundation, Opera
 * Software ASA, and others.
 *
 *
 * Status: proposal, not discussed.
 *
 * Dictionaries are hash tables mapping values to values.
 *
 * These are built on top of intrinsic::hashcode() for hashing and the
 * iterator protocol for enumeration.
 *
 * This implementation is not testable until we have parameterized
 * types and a bunch of bug fixes.
 *
 * Misc:
 *
 *  - Flash has a "Dictionary" class that's pretty different:
 *       http://livedocs.adobe.com/flex/2/langref/flash/utils/Dictionary.html
 *
 * Implementation notes:
 *
 * This implementation uses chaining for collisions and load factors
 * to trigger rehashing; neither is normative.
 *
 * A good implementation would defer creating the iterator
 * intermediate array until insertions or deletions make it necessary
 * to create it.
 */

namespace Library
{
    use namespace intrinsic;

    public class Dictionary.<K,V>
    {
        /* Hashfn is a function used to hash the keys.  The hash
         * function must always return the same value given the same
         * object.
         */
        public function Dictionary(hashfn : function(*):uint = standardHash)
            : hashfn=hashfn
        {
        }

        /* This is a little weird.  We assume we only want to capture
         * names that have no namespace, and ignore the others.  Also,
         * the key type 'K' must be 'string' for this to work.
         */
        meta static function convert(x : Object!) {
            let d = new Dictionary.<string,V>;
            for ( let n in x )
                if (!(n is Name))
                    if (x.hasOwnProperty(n))
                        d.put(n, x[n]);
            return d;
        }

        /* "Standard" hash function:
         *  - subclasses of String hash by name
         *  - empty string hashes as 0
         *  - true hashes as 1, false as 0
         *  - undefined and null hash as 0
         *  - numbers hash by conversion to uint
         *  - everything else hashes by intrinsic::hashcode()
         *
         * The function is public so that other hash users can pick it up
         * and use it.
         *
         * FIXME: Issue: should string hashing be moved to "String"?
         * If so, should it be static or a method that can be
         * overridden?
         */
        public static function standardHash(key: *): uint {
            if (key is String) {
                let h = 0;
                for ( let i = 0, limit = key.length ; i < limit ; i++ )
                    h = h << 4 | key.charCodeAt(i);
                return h;
            }

            if (key is Numeric)
                return uint(key);

            if (key === false || key === undefined || key === null)
                return 0;

            if (key === true)
                return 1;

            return intrinsic::hashcode(key);
        }

        /* Return the number of mappings in the dictionary */
        public function size() : uint
            population;

        /* Return the value associated with 'key', or null if 'key' does
         * not exist in the dictionary
         */
        public function get(key: K) : V? {
            let [l] = find(key);
            return l ? l.value : null;
        }

        /* Associate 'value' with 'key', overwriting any previous
         * association for 'key'
         */
        public function put(key:K, value:V) : void {
            let [l] = find(key);
            if (l)
                l.value = value;
            else
                insert( key, value );
        }

        /* Return true iff the dictionary has an association for 'key'
         */
        public function has(key:K) : boolean {
            let [l] = find(key);
            return l to boolean;
        }

        /* Remove any association for 'key' in the dictionary.  Returns
         * true if an association was in fact removed
         */
        public function remove(key:K) : boolean {
            let [l,p] = find(key);
            if (l) {
                if (p)
                    p.link = l.link;
                else
                    tbl[h] = l.link;
                population -= 1;
                if (population < limit*REHASH_DOWN)
                    rehash(false);
                return true;
            }
            return false;
        }

        iterator function get(deep: boolean = false) : iterator::IteratorType.<K>
            getKeys(deep);

        iterator function getKeys(deep: boolean = false) : iterator::IteratorType.<K>
            iterate.<K>(function (a,k,v) { a.push(k) });

        iterator function getValues(deep: boolean = false) : iterator::IteratorType.<V>
            iterate.<V>(function (a,k,v) { a.push(v) });

        iterator function getItems(deep: boolean = false) : iterator::IteratorType.<[K,V]>
            iterate.<[K,V]>(function (a,k,v) { a.push([k,v]) });

        private function iterate.<T>(f: function(k,v):*) {
            let a = [] : [T];
            allElements( tbl, limit, function (k,v) { f(a,k,v) } );
            let i = 0;
            return {
                next: function () : T {
                    if (i === a.length)
                        throw StopIteration;
                    return a[i++];
                }
            };
        }

        private function find(key:K): [box,box] {
            let h = hashfn(key) % limit;
            let l = tbl[h];
            let p = null;
            while (l && l.key !== key) {
                p = l;
                l = l.link;
            }
            return [l,p];
        }

        private function insert(key:K, value:V) : void {
            let hash = hashfn(key);
            if (population > limit*REHASH_UP)
                rehash(true);
            let h = hash % limit;
            let o = {key: key, value: value, link: tbl[h]};
            tbl[h] = o;
            population += 1;
        }

        private function rehash(grow: boolean) : void {
            let oldtbl = tbl;
            let oldlimit = limit;

            population = 0;
            limit = grow ? limit * 2 : limit / 2;
            tbl = newTbl(limit);

            allElements( oldtbl, oldlimit, insert );
        }

        private function allElements(tbl: [box], limit: uint, fn: function (K,V):*) {
            for ( let i=0 ; i < limit ; i++ )
                for ( let p=tbl[i] ; p ; p = p.link )
                    fn(p.key, p.value);
        }

        private static function newTbl(limit: uint) : [box] {
            let a = [] : [box];
            a.limit = limit;
            return a;
        }

        /* We need to have REHASH_UP > REHASH_DOWN*2 for things to work */

        private const REHASH_UP = 1;           /* rehash if population > REHASH_UP*limit */
        private const REHASH_DOWN = 1/3;       /* rehash if population < REHASH_DOWN*limit */

        private type box = {key:K, value:V, link:* /*box*/};

        private var hashfn : function(*):uint; /* hash function (should be const?) */
        private var population: uint = 0;      /* number of elements in the table */
        private var limit: uint = 10;          /* number of buckets in the table */
        private var tbl: [box] = newTbl(limit);/* hash table */
    }
}
